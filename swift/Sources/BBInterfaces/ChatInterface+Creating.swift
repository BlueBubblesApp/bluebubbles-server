//  ChatInterface+Creating
//  Making a chat that does not exist yet.
//
//  The one part of this interface with two entirely different implementations behind it: a
//  one-to-one chat goes through AppleScript, and a group chat needs either the Private API or
//  the user-installed Shortcut. See `create` for which is chosen and why.

import BBAppleScript
import BBCore
import BBIMessage
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import BBShortcuts
import Foundation
import Logging

extension ChatInterface {

  // MARK: - Creating a chat

  /// Which backend created a chat, or would.
  ///
  /// Reported rather than discovered, for the same reason `MessageInterface.SendBackend`
  /// is: a user without the helper should be told what they have before they try, not meet
  /// a refusal at the moment they act.
  public enum CreateBackend: String, Sendable {
    case privateAPI = "private-api"
    /// One-to-one only. Nothing is explicitly created: sending to a participant with no
    /// conversation makes Messages open one.
    case appleScript = "apple-script"
    /// Groups, without the helper. See `BBShortcuts`.
    case shortcut
  }

  /// Creates a chat and returns its GUID.
  ///
  /// THREE BACKENDS, AND THE ORDER IS NOT NEGOTIABLE
  /// ----------------------------------------------
  /// 1. **The Private API**, when connected. It creates either kind, needs no first
  ///    message, and returns the GUID directly.
  /// 2. **AppleScript**, for a ONE-TO-ONE chat only. It cannot create anything explicitly:
  ///    `make new chat` has been a stub since Big Sur, three releases below this package's
  ///    floor, so the chat comes into existence as a side effect of sending to the
  ///    participant. That is why a first message is required without the helper.
  /// 3. **The Shortcut**, for a GROUP, and only if the user has installed it. There is no
  ///    other route: `is.workflow.actions.sendmessage` is the only messaging action on the
  ///    system, and AppleScript has no group path on any supported macOS.
  ///
  /// **Do not add an AppleScript attempt before the Shortcut for groups.** It cannot
  /// succeed on macOS 14, 15 or 26, and the failed round trip would be paid on every group
  /// a user creates. See `MessagesScripts` for the measurements.
  public func create(
    addresses: [String],
    service: String = "iMessage",
    message: String? = nil
  ) async throws -> String {
    guard !addresses.isEmpty else {
      throw InterfaceError.invalidRequest("at least one address is required")
    }

    if let privateAPI, await privateAPI.isConnected {
      let guid = try await throughMessages {
        try await privateAPI.createChat(
          addresses: addresses, service: service, message: message
        )
      }
      return guid.rawValue
    }

    // Everything below creates the chat BY SENDING, so there has to be something to send.
    // Stated as a 400 with the reason rather than a generic failure: the caller can fix it,
    // and the Private API genuinely does not need it, so "a message is required" alone
    // would read as a contradiction of the documented contract.
    guard let message, !message.isEmpty else {
      throw InterfaceError.invalidRequest(
        "a message is required when creating a chat without the Private API, because the "
          + "chat is created by sending the first message"
      )
    }

    let resolved = MessagingService(rawValue: service) ?? .iMessage
    if addresses.count == 1 {
      return try await createDirectChat(
        address: addresses[0], service: resolved, message: message
      )
    }
    return try await createGroupChat(
      addresses: addresses, service: resolved, message: message
    )
  }

  /// A one-to-one chat, opened by sending to the participant.
  private func createDirectChat(
    address: String, service: MessagingService, message: String
  ) async throws -> String {
    let formatted = try await throughMessages {
      try await appleScript.send(address: address, service: service, text: message)
    }
    // The send reports the address it used, not a GUID, so the chat is looked up the same
    // way the group path does it.
    //
    // The Node server INFERRED the GUID here instead (`${service};-;${address}`) and
    // returned it without checking. That is no longer safe: macOS 26 rewrote every chat
    // GUID prefix to the literal `any`, so the inferred spelling matches no row and a
    // client that stored it would address a chat the database does not have. Reading the
    // real GUID back costs one query and is correct on every version.
    //
    // The inferred form is still the fallback, so a database that has not caught up yet
    // returns what the Node server did rather than failing.
    // A short deadline, unlike the group path: this one has a correct answer to fall back
    // on, so waiting half a minute to avoid using it would be the wrong trade.
    if let guid = try await resolveChat(addresses: [formatted], waitFor: .seconds(5)) {
      return guid
    }
    return "\(service.rawValue);-;\(formatted)"
  }

  /// A group chat, through the user-installed Shortcut.
  private func createGroupChat(
    addresses: [String], service: MessagingService, message: String
  ) async throws -> String {
    guard let shortcuts, await shortcuts.isInstalled() else {
      throw InterfaceError.capabilityUnavailable(
        "Creating a group chat needs either the Private API or the BlueBubbles group chat "
          + "Shortcut. Install the Shortcut from Settings › General › Features.",
        feature: "creating a group chat"
      )
    }
    let formatted = addresses.map { addressFormatter.iMessageFormat($0) }
    try await throughMessages {
      try await shortcuts.send(recipients: formatted, message: message)
    }

    guard let guid = try await resolveChat(addresses: formatted, waitFor: .seconds(30)) else {
      // The send succeeded and the chat is not in the database yet, or Messages routed it
      // somewhere the participant set does not describe. Reported honestly rather than
      // returning a GUID we guessed: a client that stores a wrong one sends every later
      // message into the void.
      throw InterfaceError.messagesFailed(
        "The group chat Shortcut ran, but the new chat could not be found in the message "
          + "database. It may still appear in Messages."
      )
    }
    return guid
  }

  /// Finds the chat whose participants are exactly `addresses`, waiting for it to appear.
  ///
  /// POLLING IS NOT OPTIONAL HERE. The Shortcuts send action returns nothing at all (no
  /// GUID, no identifier, no output of any kind) so the only way to name the chat that was
  /// just created is to find it by its participants. `chat.db` is written by Messages after
  /// the send returns, so the row is reliably absent for the first moment.
  ///
  /// - Parameter waitFor: How long to keep looking. The group path uses the same deadline
  ///   the Node server used for its equivalent wait, because it has no fallback and a slow
  ///   Mac must still succeed. The direct path uses a much shorter one: it can infer a
  ///   correct GUID, so a long wait would buy nothing.
  private func resolveChat(
    addresses: [String], waitFor timeout: Duration
  ) async throws -> String? {
    let deadline = Date().addingTimeInterval(
      Double(timeout.components.seconds))
    let normalize: @Sendable (String) -> String = { [addressFormatter] in
      addressFormatter.iMessageFormat($0)
    }
    while true {
      let matches = try await repository.chats(
        matchingParticipants: addresses, normalize: normalize)
      if let newest = matches.first { return newest.guid }
      guard Date() < deadline else { return nil }
      try? await Task.sleep(for: .milliseconds(500))
    }
  }

  /// One chat's row, or a refusal naming the GUID.
  ///
  /// Distinct from `find(guid:query:)`, which builds a projection with its relations. The
  /// group-icon and background routes want the row itself and nothing loaded alongside it.
  public func row(guid: String) async throws -> ChatRow {
    guard let chat = try await repository.chat(guid: guid) else {
      throw InterfaceError.notFound(ReferenceMessages.chatNotFound)
    }
    return chat
  }

  /// The group photo on disk, for a chat that has one.
  ///
  /// Reads Messages' own photo directory: no helper needed, which is why the route is scoped
  /// to `attachments:read` rather than requiring the Private API. Two distinct refusals: the
  /// chat does not exist, or it exists and has never had a photo set.
  public func groupIconPath(guid: String) async throws -> String {
    let chat = try await row(guid: guid)
    guard let path = GroupIconStore.path(forGroupID: chat.groupID) else {
      throw InterfaceError.notFound(ReferenceMessages.chatIconNotFound)
    }
    return path
  }
}
