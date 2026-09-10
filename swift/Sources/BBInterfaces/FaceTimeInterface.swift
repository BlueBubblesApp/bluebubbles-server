//  FaceTimeInterface
//  What each FaceTime operation MEANS, independent of how it was asked for.
//
//  Three flows (docs/headers/FACETIME.md):
//    A. Mint a link, hand it back.                          → `mintLink`
//    B. Dial the person, hand back a link.                  → `placeCall`
//    C. Answer an incoming call, hand back a link, drop.    → `handOff`, and `answer`
//
//  The hand-off (admit joiners, leave once a client has really joined) is
//  `FaceTimeHandOff`, owned by `FaceTimeCoordinator`. This interface starts it and answers.
//
//  Built PER CALL by the composition root, because the helper connects and drops while the
//  server runs; the coordinator and its link ledger are the long-lived half and are shared.
//  The setting gates (`enable_ft_private_api`, `facetime_outgoing_calls`) stay in the
//  handlers: they are refusals with an HTTP spelling, and the app is not refused by its own
//  switch.

import BBFaceTime
import BBPrivateAPIContract
import Foundation
import Logging

public struct FaceTimeInterface: MessagesBackedInterface {

  /// The whole client rather than a role composition, because `beginHandOff` hands the
  /// helper to a watcher that polls members and leaves the call, and the coordinator takes
  /// the composed protocol for that.
  public typealias Helper = any PrivateAPI

  let privateAPI: Helper?
  let logger: Logger
  private let coordinator: FaceTimeCoordinator

  public init(
    coordinator: FaceTimeCoordinator,
    privateAPI: Helper?,
    logger: Logger = Logger(label: "bluebubbles.interface.facetime")
  ) {
    self.coordinator = coordinator
    self.privateAPI = privateAPI
    self.logger = logger
  }

  /// What `placeCall` produced: the call that is now ringing, and the link minted for it.
  ///
  /// `link` is nil when the call went through and the link did not. The call is LIVE either
  /// way, and the caller decides how to say so: the HTTP projection is an error that carries
  /// the call, so a client can retry the link or hang up deliberately.
  public struct PlacedCall: Sendable {
    public let call: FaceTimeCall
    public let link: FaceTimeLink?
  }

  // MARK: - Flow A: links

  /// Mints a link for a new conversation and records it in the ledger, so cleanup can find it.
  ///
  /// `invitedAddresses` pre-invites those people onto the link. There is NO media option,
  /// deliberately: a `TUConversationLink` carries no media type; whoever joins picks their
  /// own camera. Choosing audio vs video is a property of placing a CALL, so it lives on
  /// `placeCall`.
  public func mintLink(invitedAddresses: [String] = []) async throws -> FaceTimeLink {
    let api = try requirePrivateAPI(for: "creating a FaceTime link")
    let link = try await throughMessages {
      try await api.generateFaceTimeLink(invitedAddresses: invitedAddresses)
    }
    await coordinator.links.record(url: link.url, groupUUID: link.groupUUID)
    return link
  }

  /// Invalidates active links and returns the URLs it invalidated. `urls` nil means every
  /// link the server minted: the cleanup path.
  public func invalidateLinks(urls: [String]?) async throws -> [String] {
    let api = try requirePrivateAPI(for: "invalidating FaceTime links")
    return try await throughMessages { try await api.invalidateFaceTimeLinks(urls: urls) }
  }

  // MARK: - Flow B: an outgoing call

  /// Dials `addresses` and mints a link for the call.
  ///
  /// ALWAYS dials: deliberately not switchable. Branching on a server-side mode whose other
  /// value minted a bare link instead would mean the same request either rang somebody or did
  /// not, depending on configuration the client cannot see. A caller that wants a bare link
  /// asks `mintLink`.
  public func placeCall(addresses: [String], video: Bool) async throws -> PlacedCall {
    let api = try requirePrivateAPI(for: "starting a FaceTime call")
    guard !addresses.isEmpty else {
      throw InterfaceError.invalidRequest("`address` is required to place a call")
    }

    // PRE-FLIGHT. Dialling an address that is not FaceTime-capable does not fail: a
    // `TUCall` is created and reports `outgoing`, so the API answered "the call was
    // placed" while FaceTime.app quietly put up "…is not available for FaceTime" and no
    // conversation ever formed. Checked here so the honest error arrives BEFORE a phantom
    // call exists.
    try await Self.requireFaceTimeCapable(
      addresses,
      isAvailable: { try await api.checkFaceTimeAvailability(address: $0) },
      logger: logger
    )

    let call = try await throughMessages {
      try await api.dialFaceTime(FaceTimeStartRequest(addresses: addresses, video: video))
    }

    // Mint the link, but do NOT let a link failure strand the Mac.
    //
    // The moment the dial returns, the Mac is a live participant in a call it placed.
    // Arming the hand-off watcher only AFTER a successful link meant any failure in between
    // left the Mac sitting in the call indefinitely: observed on a live call, where the
    // callee answered and the Mac never left. So the watcher is armed off the CALL, and the
    // link is reported separately.
    let link: FaceTimeLink?
    do {
      link = try await api.generateFaceTimeLinkForCall(callUUID: call.callUUID)
    } catch {
      link = nil
      logger.warning(
        "The FaceTime call was placed but no link could be minted for it",
        metadata: [
          "call": .string(call.callUUID),
          "error": .string(String(describing: error)),
        ])
    }
    if let link {
      await coordinator.links.record(url: link.url, groupUUID: link.groupUUID)
    }

    if let group = link?.groupUUID ?? call.groupUUID {
      // Owned by the coordinator, which marks the call so cleanup never hangs up on a
      // hand-off that is still running, and cancels it if the Private API goes away.
      await coordinator.beginHandOff(
        api: api, callUUID: call.callUUID, conversationUUID: group,
        dialledAddresses: addresses
      )
    }
    return PlacedCall(call: call, link: link)
  }

  /// Refuses addresses FaceTime cannot call, before a call object exists.
  ///
  /// An UNVERIFIABLE address is allowed through. The check runs through the Messages helper,
  /// so on a server with only the FaceTime helper injected it cannot answer, and refusing
  /// every call because the check is unavailable would be worse than the confusing error
  /// this exists to prevent. Only a definite "not available" blocks.
  ///
  /// Takes the availability CHECK rather than the whole API, so the rule (including the
  /// "unverifiable passes through" branch, which is the one that matters and the easiest to
  /// get wrong) is testable without stubbing sixty unrelated methods.
  static func requireFaceTimeCapable(
    _ addresses: [String],
    isAvailable: (String) async throws -> Bool,
    logger: Logger
  ) async throws {
    var unavailable: [String] = []
    for address in addresses {
      do {
        if try await isAvailable(address) == false {
          unavailable.append(address)
        }
      } catch {
        logger.debug(
          "Could not verify FaceTime availability; dialling anyway",
          metadata: [
            "address": .string(address),
            "error": .string(String(describing: error)),
          ])
      }
    }
    guard unavailable.isEmpty else {
      throw InterfaceError.invalidRequest(
        "Not reachable on FaceTime: \(unavailable.joined(separator: ", ")). "
          + "FaceTime rejects the call without ringing, so no call was placed."
      )
    }
  }

  // MARK: - Flow C: an incoming call

  /// Answers a ringing call and mints a link for it. Answering a 1:1 call and minting a link
  /// upgrades it to a joinable conversation. No hand-off: the Mac stays in the call.
  public func answer(callUUID: String) async throws -> FaceTimeLink {
    let api = try requirePrivateAPI(for: "answering a FaceTime call")
    return try await throughMessages {
      try await api.answerFaceTimeCall(callUUID: callUUID)
      return try await api.generateFaceTimeLinkForCall(callUUID: callUUID)
    }
  }

  /// Answers a ringing call, mints a link, and starts the hand-off: admit joiners and drop
  /// the Mac once someone actually has, never on a timer alone.
  ///
  /// Returns as soon as the link exists, so the caller can join immediately; the hand-off
  /// runs under the coordinator.
  public func handOff(callUUID: String) async throws -> FaceTimeLink {
    let api = try requirePrivateAPI(for: "handing off a FaceTime call")
    let link = try await throughMessages {
      try await api.answerFaceTimeCall(callUUID: callUUID)
      return try await api.generateFaceTimeLinkForCall(callUUID: callUUID)
    }
    if let group = link.groupUUID {
      await coordinator.beginHandOff(api: api, callUUID: callUUID, conversationUUID: group)
    }
    return link
  }

  /// Hangs up the Mac's side of a call.
  public func leave(callUUID: String) async throws {
    let api = try requirePrivateAPI(for: "leaving a FaceTime call")
    try await throughMessages { try await api.leaveFaceTimeCall(callUUID: callUUID) }
  }

  // MARK: - Conversations

  /// Admits someone knocking at a conversation's waiting room.
  public func admit(conversationUUID: String, address: String) async throws {
    let api = try requirePrivateAPI(for: "admitting a FaceTime participant")
    try await throughMessages {
      try await api.admitFaceTimeParticipant(conversationUUID: conversationUUID, handle: address)
    }
  }

  /// Who is in a conversation, and who is knocking.
  public func members(conversationUUID: String) async throws -> [FaceTimeMember] {
    let api = try requirePrivateAPI(for: "reading FaceTime members")
    return try await throughMessages {
      try await api.faceTimeMembers(conversationUUID: conversationUUID)
    }
  }

  /// Clears every link the server minted and any call the Mac is stuck in. "Clear them
  /// now", not "clear the old ones": the coordinator's periodic pass is the other mode.
  public func cleanUp() async throws -> FaceTimeCoordinator.CleanupResult {
    _ = try requirePrivateAPI(for: "cleaning up FaceTime state")
    return await coordinator.cleanUp(clearAll: true)
  }

  // MARK: - Diagnostics

  /// Raw TelephonyUtilities state for a conversation. A diagnostic, not a product API.
  public func debugState(conversationUUID: String) async throws -> [String: String] {
    let api = try requirePrivateAPI(for: "reading FaceTime debug state")
    return try await throughMessages {
      try await api.faceTimeDebugState(conversationUUID: conversationUUID)
    }
  }

  /// What FaceTime.app is showing on screen.
  public func windows() async throws -> [String] {
    let api = try requirePrivateAPI(for: "inspecting FaceTime windows")
    return try await throughMessages { try await api.faceTimeWindows() }
  }

  /// Cancels a blocking alert in FaceTime.app and reports how many were dismissed.
  public func dismissAlert() async throws -> Int {
    let api = try requirePrivateAPI(for: "dismissing a FaceTime alert")
    return try await throughMessages { try await api.dismissFaceTimeAlert() }
  }
}
