//  FaceTimeBridge+Links
//  Minting a FaceTime link (Flow A), either for a conversation with no call or for a call the
//  Mac is already in (Flows B and C), and reading the link back into the contract's shape.
//
//  One flow's worth of `FaceTimeBridge`. The static state it reads and writes is declared
//  in `FaceTimeBridge.swift`, beside the enum.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension FaceTimeBridge {

  // MARK: - Links (Flow A, and link-for-call in B/C)

  /// Mints a link for a NEW conversation, no call placed. Flow A.
  ///
  /// `invitedAddresses` pre-invites those people onto the link. Whether that RINGS them or
  /// only adds a passive invitation is the thing under test; either way the Mac never joins
  /// a call, so there is nothing to leave.
  static func generateLink(invitedAddresses: [String] = []) async throws -> FaceTimeLink {
    let client = try await ensureClient()
    let handles = invitedAddresses.compactMap(makeHandle)
    return try await generateLink(on: client, forConversation: nil, invitedHandles: handles)
  }

  /// Mints a link for an EXISTING call the Mac is in. Flow B/C.
  ///
  /// The conversation is POLLED rather than read once. A freshly-dialled call has no active
  /// conversation at the instant `dialWithRequest:` returns: the call has to establish
  /// first, so reading immediately yields nil and the link generation fails with no
  /// explanation. Measured: a dial that rang and connected still produced "FaceTime
  /// returned no link" because this ran too early.
  static func generateLink(forCall callUUID: String) async throws -> FaceTimeLink {
    let client = try await ensureClient()
    let center = try callCenter()

    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    var conversation: AnyObject?
    var sawCall = false

    while ContinuousClock.now < deadline {
      if let call = try IMCoreRuntime.send(center, "callWithCallUUID:", callUUID) {
        sawCall = true
        if let active = try? IMCoreRuntime.send(center, "activeConversationForCall:", call) {
          conversation = active
          break
        }
      }
      // `try`, not `try?`: a cancelled sleep returns at once, and this loop then made an
      // IMCore call on FaceTime's main thread as fast as it could until the deadline.
      try await Task.sleep(for: .milliseconds(500))
    }

    guard let conversation else {
      // Distinguish the two failures: a call we never found (wrong UUID, or it ended)
      // versus one that exists but never grew a conversation.
      throw PrivateAPIError.rejectedByMessages(
        reason: sawCall
          ? "call \(callUUID) never became an active conversation within 15s"
          : "no FaceTime call with UUID \(callUUID)"
      )
    }
    return try await generateLink(on: client, forConversation: conversation)
  }

  /// The shared link-minting path. `conversation` nil means "a fresh link with no call."
  private static func generateLink(
    on client: AnyObject,
    forConversation conversation: AnyObject?,
    invitedHandles: [AnyObject] = []
  ) async throws -> FaceTimeLink {
    // The completion is `(TUConversationLink *, NSError *)`: TWO arguments. A one-arg
    // block would silently drop the error, leaving "returned no link" with no cause; the
    // two-arg shape captures both so a daemon-side failure is reported.
    let reply: CompletionReply
    if let conversation {
      reply = await callAwaitingCompletion(
        client, "generateLinkForConversation:completionHandler:",
        leading: [conversation], shape: .objectAndError)
    } else {
      // `linkLifetimeScope: 0` is the default the ObjC helper uses; an empty invited set
      // means "a link anyone with the URL can use." Non-empty pre-invites those handles.
      reply = await callAwaitingCompletion(
        client, "generateLinkWithInvitedMemberHandles:linkLifetimeScope:completionHandler:",
        leading: [invitedHandles, NSNumber(value: 0)], shape: .objectAndError)
    }

    guard let link = reply.object else {
      let detail = reply.failure.map { ": \($0)" } ?? ""
      throw PrivateAPIError.rejectedByMessages(reason: "FaceTime returned no link\(detail)")
    }
    return try decodeLink(link)
  }

  /// Reads a `TUConversationLink` into the contract's shape.
  private static func decodeLink(_ link: AnyObject) throws -> FaceTimeLink {
    guard let url = try? IMCoreRuntime.send(link, "URL"),
      let string = ((try? IMCoreRuntime.string(url, "absoluteString")) ?? nil),
      !string.isEmpty
    else {
      throw PrivateAPIError.rejectedByMessages(reason: "the FaceTime link has no URL")
    }
    let groupUUID = (try? IMCoreRuntime.send(link, "groupUUID"))
      .flatMap { try? IMCoreRuntime.string($0, "UUIDString") ?? nil }
    let expiration = (try? IMCoreRuntime.send(link, "expirationDate")) as? Date
    return FaceTimeLink(
      url: string,
      groupUUID: groupUUID,
      name: (try? IMCoreRuntime.string(link, "linkName")) ?? nil,
      expiresAt: expiration
    )
  }
}
