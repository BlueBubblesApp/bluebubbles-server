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

  /// A chat that has just been created, with what the reference hands back alongside it.
  ///
  /// **`POST /chat/new` does not answer with a GUID.** `chatRouter.create` serializes the
  /// whole chat with `includeParticipants: true, includeMessages: true` and then writes the
  /// client's `tempGuid` onto each message, so a client can match the message it rendered
  /// optimistically against the row Messages actually wrote. This server answered
  /// `{"guid": "…"}`, twelve keys short of the contract, and nothing caught it: the recorded
  /// reference response is in `Fixtures/http/post_api_v1_chat_new-…json` and the replay
  /// harness deny-lists the route as a send, so it is never compared.
  public struct CreatedChat: Sendable {
    public let projection: ChatProjection
    /// The message the create SENT, when the backend could name it.
    ///
    /// The Private API path always can: its answer IS a message GUID. AppleScript matches the
    /// row back by text, the way every other AppleScript send does. The Shortcut path never
    /// can — the Shortcuts send action returns nothing at all — so a group created without
    /// the helper reports `messages: []`: the same shape with one fewer element, not a
    /// missing key.
    public let firstMessage: MessageInterface.MessageProjection?

    public var guid: String { projection.row.guid }
  }

  /// What one backend managed to name. Always the chat; the message when it can.
  private struct CreateOutcome {
    let guid: String
    let message: MessageInterface.MessageProjection?
  }

  /// Creates a chat and returns it, with its participants and its first message.
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
  ) async throws -> CreatedChat {
    guard !addresses.isEmpty else {
      throw InterfaceError.invalidRequest("at least one address is required")
    }

    if let privateAPI, await privateAPI.isConnected {
      logCreating(via: "private-api", participants: addresses.count, service: service)
      let identifier = try await throughMessages {
        try await privateAPI.createChat(
          addresses: addresses, service: service, message: message
        )
      }
      // **`identifier` is a MESSAGE guid, not a chat guid.** `PrivateAPIClient.createChat`
      // says so on the wire field and the reference flags it "Yes this is correct"; this
      // returned it verbatim as the chat GUID, so on the primary configuration — a server
      // WITH the helper — `POST /chat/new` answered with a message GUID in the `guid` field
      // and a client that stored it addressed a chat that does not exist. Found while
      // giving the route its real response body; the resolution below is the reference's
      // (`chatInterface.ts:170-208`: wait for the message, take `messages.chats[0].guid`).
      return try await completed(
        try await resolveCreated(fromMessageGUID: identifier.rawValue), via: "private-api")
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
      logCreating(via: "apple-script", participants: 1, service: service)
      return try await completed(
        try await createDirectChat(
          address: addresses[0], service: resolved, message: message
        ), via: "apple-script")
    }
    logCreating(via: "shortcut", participants: addresses.count, service: service)
    return try await completed(
      try await createGroupChat(
        addresses: addresses, service: resolved, message: message
      ), via: "shortcut")
  }

  /// Turns a backend's answer into the chat a client is handed.
  ///
  /// One place, after all three backends, so the response body cannot depend on which one
  /// ran. Participants are loaded because the reference serializes with
  /// `DEFAULT_CHAT_CONFIG` (`includeParticipants: true`) and its own create loads the chat
  /// `withParticipants: true`; a client reads `.participants.length` to decide whether it
  /// has a group.
  private func completed(_ outcome: CreateOutcome, via backend: String) async throws
    -> CreatedChat
  {
    guard let row = try await repository.chat(guid: outcome.guid) else {
      // The send succeeded and the row is not readable. Reported rather than papered over:
      // there is no chat to serialize, and answering 200 with a body built from a GUID we
      // guessed would hand a client an object describing a chat that is not there.
      throw InterfaceError.messagesFailed(
        "The chat was created, but it could not be found in the message database. It may "
          + "still appear in Messages."
      )
    }
    logCreated(row.guid, via: backend)
    return CreatedChat(
      projection: ChatProjection(
        row: row,
        participants: try await repository.participants(chatGUID: row.guid),
        lastMessage: nil,
        // The `with=lastMessage` pair, which this route is not: `messages` here carries the
        // message that was just sent, and `lastMessage` is not a key `chat/new` emits.
        wantsLastMessage: false
      ),
      firstMessage: outcome.message
    )
  }

  /// Waits for the row behind a Private API create and reads the chat off it.
  ///
  /// **Waits for the CHATS, not for the message.** `chat_message_join` is written after the
  /// message row (measured; see the root guide), so a loop that stops as soon as
  /// `message(guid:)` answers gets a row with no chat attached and resolves nothing. The
  /// reference's condition is the same one: `isEmpty(message?.chats)`.
  ///
  /// Thirty seconds, which is the reference's `maxWaitMs` for this exact wait. Unlike the
  /// AppleScript path there is no GUID to infer as a fallback, so the wait has to be long
  /// enough for a slow Mac.
  private func resolveCreated(fromMessageGUID messageGUID: String) async throws
    -> CreateOutcome
  {
    let deadline = Date().addingTimeInterval(30)
    while true {
      // Checked, and the sleep below THROWS, for the reason `resolveChat` gives: a `try?`
      // here turns a cancelled request into a hot loop against chat.db.
      try Task.checkCancellation()
      if let chat = try await repository.chats(forMessageGUID: messageGUID).first {
        return CreateOutcome(
          guid: chat.guid,
          message: try await sentMessage(guid: messageGUID)
        )
      }
      guard Date() < deadline else {
        throw InterfaceError.messagesFailed(
          "Messages accepted the new chat, but it did not appear in the message database "
            + "within 30 seconds."
        )
      }
      try await Task.sleep(for: .milliseconds(500))
    }
  }

  /// The sent message as the nested `messages[0]`.
  ///
  /// Its handle and nothing else, matching what the reference's `ChatSerializer` asks for:
  /// it overrides `includeChats: false` on the message config and leaves the rest at
  /// `DEFAULT_MESSAGE_CONFIG`, so the blob columns are NOT parsed here. Measured against the
  /// recorded fixture, whose nested message carries `attributedBody: null` and
  /// `messageSummaryInfo: null` where the same message on `POST /message/text` has both
  /// decoded. Nil rather than throwing: the chat is the answer, and a message we could not
  /// read back is one fewer array element, not a failed create.
  private func sentMessage(guid: String) async throws -> MessageInterface.MessageProjection? {
    guard let row = try await repository.message(guid: guid) else { return nil }
    var context = MessageSerializer.Context()
    if let handleID = row.handleID {
      context.handle = try await repository.handle(rowID: handleID)
    }
    return MessageInterface.MessageProjection(row: row, relations: context)
  }

  /// Which of the three ways a chat can be created was taken. A count of participants
  /// rather than the addresses: the addresses are people.
  private func logCreating(via backend: String, participants: Int, service: String) {
    logger.debug(
      "Creating chat",
      metadata: [
        "backend": .string(backend),
        "participantCount": .stringConvertible(participants),
        "service": .string(service),
      ])
  }

  private func logCreated(_ guid: String, via backend: String) {
    logger.info(
      "Chat created",
      metadata: [
        "backend": .string(backend),
        "chat": .string(Redaction.chatGUID(guid)),
      ])
  }

  /// A one-to-one chat, opened by sending to the participant.
  private func createDirectChat(
    address: String, service: MessagingService, message: String
  ) async throws -> CreateOutcome {
    // Stamped BEFORE the send, for the reason `MessageInterface` gives at its own
    // AppleScript call site: Messages back-dates rows, and a window opening after the
    // script returns misses them.
    let sentAt = MessageInterface.hydrationWindowStart()
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
    // The SAME deadline as the group path, which is also the reference's for this wait.
    //
    // It was five seconds, justified by "this one has a correct answer to fall back on, so
    // waiting half a minute to avoid using it would be the wrong trade". That stopped being
    // true when the route started answering with the chat itself rather than with a GUID:
    // there is no response body to build from an inferred string, so a row that has not
    // landed yet is now a 500 rather than a slightly-wrong GUID, and the wait has to be long
    // enough for a slow Mac.
    //
    // The fallback is kept and still earns its place: `resolveChat` matches on the
    // participant set, `repository.chat(guid:)` is service-prefix tolerant, and the two miss
    // in different ways, so trying the inferred spelling catches a row the participant query
    // did not. On success neither wait is paid — `resolveChat` returns as soon as the row
    // appears — so this costs nothing except in the case that used to answer wrongly.
    let guid =
      try await resolveChat(addresses: [formatted], waitFor: .seconds(30))
      ?? "\(service.rawValue);-;\(formatted)"

    // The message the create sent, matched back by text the way every other AppleScript
    // send does. The reference attaches it too: its Big Sur+ path goes through
    // `MessageInterface.sendMessageSync` and then sets `chat.messages = [sentMessage]`.
    return CreateOutcome(
      guid: guid,
      message: try await MessageInterface(repository: repository, serializer: serializer)
        .awaitSentMessage(inChat: guid, text: message, sentAfter: sentAt)
    )
  }

  /// A group chat, through the user-installed Shortcut.
  private func createGroupChat(
    addresses: [String], service: MessagingService, message: String
  ) async throws -> CreateOutcome {
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
    // No message. The Shortcuts send action returns nothing at all — which is why the chat
    // itself has to be found by its participants above — so there is nothing to match a row
    // back to. The reference has no Shortcut path to be out of step with: it cannot create a
    // group without the helper at all.
    return CreateOutcome(guid: guid, message: nil)
  }

  /// Finds the chat whose participants are exactly `addresses`, waiting for it to appear.
  ///
  /// POLLING IS NOT OPTIONAL HERE. The Shortcuts send action returns nothing at all (no
  /// GUID, no identifier, no output of any kind) so the only way to name the chat that was
  /// just created is to find it by its participants. `chat.db` is written by Messages after
  /// the send returns, so the row is reliably absent for the first moment.
  ///
  /// - Parameter waitFor: How long to keep looking. Thirty seconds on both paths, which is
  ///   the deadline the Node server uses for its equivalent wait. The direct path used to
  ///   pass five, on the grounds that it could infer a correct GUID if the row was late;
  ///   see `createDirectChat` for why answering with the chat rather than with a GUID took
  ///   that fallback away. Nothing is paid on success: this returns as soon as the row
  ///   appears.
  private func resolveChat(
    addresses: [String], waitFor timeout: Duration
  ) async throws -> String? {
    let deadline = Date().addingTimeInterval(
      Double(timeout.components.seconds))
    let normalize: @Sendable (String) -> String = { [addressFormatter] in
      addressFormatter.iMessageFormat($0)
    }
    while true {
      // CHECKED, and the sleep below THROWS. `try?` on the sleep swallowed cancellation, so
      // once the task was cancelled the sleep returned instantly and this loop spun the
      // participant query as fast as it could until the wall-clock deadline — up to thirty
      // seconds on the group path, against a query that is itself an N+1 over every
      // candidate chat. A cancelled request should stop, not become a hot loop.
      try Task.checkCancellation()
      let matches = try await repository.chats(
        matchingParticipants: addresses, normalize: normalize)
      if let newest = matches.first { return newest.guid }
      guard Date() < deadline else { return nil }
      try await Task.sleep(for: .milliseconds(500))
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
