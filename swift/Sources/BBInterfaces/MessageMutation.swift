//  MessageMutation
//  Changing a message that already exists, and the operations only the helper can perform.
//
//  Split out of `MessageInterface.swift` with `MessageSending.swift`; see that file's header
//  for why. Each of these throws rather than degrading, so a client can tell "this needs a
//  feature you do not have" from "this went wrong".

import BBCapabilities
import BBCore
import BBIMessage
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import Foundation

extension MessageInterface {
  // MARK: - Private-API-only operations
  //
  // Each of these throws `unavailableWithoutPrivateAPI` rather than a generic failure, so a
  // client can tell "this needs a feature you do not have" from "this went wrong".

  /// Sends a tapback and answers with the tapback's OWN message.
  ///
  /// A reaction is an ordinary message carrying an association, so it gets a row of its own
  /// and the route returns that row — not the message being reacted to. Same hydration as a
  /// send, because it IS a send.
  public func react(
    chatGUID: String,
    targetGUID: String,
    reaction: String,
    partIndex: Int = 0,
    emoji: String? = nil
  ) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "reactions")
    guard let type = ReactionType(rawValue: reaction) else {
      throw InterfaceError.invalidRequest("unknown reaction type: \(reaction)")
    }
    // `emoji` / `-emoji` carry the emoji in its own field; without one there is nothing
    // to send. A named tapback ignores the field rather than refusing it.
    if type.isEmoji {
      try Self.checkEmojiReactionSupported()
      if (emoji ?? "").isEmpty {
        throw InterfaceError.invalidRequest("an `emoji` is required for the emoji reaction")
      }
    }
    // The reference reads the target first and refuses a reaction to a message it does not
    // have, before reaching Messages at all — so a bad `selectedMessageGuid` is a 400 rather
    // than whatever IMCore says about it.
    try await requireMessage(targetGUID)

    let sent = try await throughMessages {
      try await api.react(
        ReactionRequest(
          chat: ChatIdentifier(chatGUID),
          target: MessageGUID(targetGUID),
          reaction: type,
          partIndex: partIndex,
          emoji: type.isEmoji ? emoji : nil
        )
      )
    }
    return SendOutcome(
      backend: .privateAPI,
      messageGUID: sent.guid.rawValue,
      message: try await awaitSentMessage(guid: sent.guid.rawValue)
    )
  }

  /// Places a sticker on a message part and answers with the sticker's OWN message.
  ///
  /// The reaction route's shape with an attachment's input: a sticker is an association
  /// (`associatedMessageType` 1000, the value the serializer already spells `"sticker"`)
  /// whose payload is a file transfer, so it needs the target message a tapback needs and
  /// the staged file an attachment needs. Same hydration as a send, because it IS a send —
  /// the row appears in chat.db with `associated_message_guid = p:<part>/<target>` and an
  /// attachment row flagged `is_sticker`.
  ///
  /// Private API only: AppleScript has no notion of an association at all.
  public func sendSticker(
    chatGUID: String,
    filePath: String,
    targetGUID: String,
    partIndex: Int = 0,
    placement: StickerPlacement = .centered,
    asTapback: Bool = false,
    isRemoval: Bool = false
  ) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "stickers")
    guard FileManager.default.fileExists(atPath: filePath) else {
      throw InterfaceError.invalidRequest("no file at \(filePath)")
    }
    // As `react`: a target this server does not have is a 400, before Messages is asked.
    try await requireMessage(targetGUID)

    let sent = try await throughMessages {
      try await api.sendSticker(
        SendStickerRequest(
          chat: ChatIdentifier(chatGUID),
          // Messages cannot read outside its container; see AttachmentStaging.
          filePath: try AttachmentStaging.stage(filePath),
          target: MessageGUID(targetGUID),
          partIndex: partIndex,
          placement: placement,
          asTapback: asTapback,
          isRemoval: isRemoval
        )
      )
    }
    return SendOutcome(
      backend: .privateAPI,
      messageGUID: sent.guid.rawValue,
      message: try await awaitSentMessage(guid: sent.guid.rawValue)
    )
  }

  /// Send Later's floor and its one sanity rule.
  ///
  /// macOS 15 is where `scheduleType`/`scheduleState` appeared on `IMMessage`; the helper
  /// refuses below that too, on the selector, but a version answer is clearer than a
  /// "selector missing" one. A date in the past would be delivered immediately by Messages,
  /// which is the opposite of what the caller asked for, so it is refused here — the one
  /// minute of slack absorbs clock skew between a client and this Mac.
  static func checkScheduledSend(
    _ date: Date,
    now: Date = Date(),
    majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  ) throws {
    guard majorVersion >= PrivateAPICapability.sendLater.minimumMacOS else {
      throw InterfaceError.invalidRequest(
        "Send Later is only supported on macOS Sequoia (15) and newer"
      )
    }
    guard date.timeIntervalSince(now) > -60 else {
      throw InterfaceError.invalidRequest("`scheduledFor` must be in the future")
    }
  }

  /// Cancels a scheduled message before Messages delivers it.
  ///
  /// The chat is required for the same reason every other message action requires it: an
  /// `IMMessageItem` fetched by GUID reports no chat identifier.
  public func cancelScheduledMessage(chatGUID: String, messageGUID: String) async throws {
    let api = try requirePrivateAPI(for: "Send Later")
    try await requireMessage(messageGUID)
    try await throughMessages {
      try await api.cancelScheduledMessage(
        MessageGUID(messageGUID), in: ChatIdentifier(chatGUID))
    }
  }

  /// Moves a scheduled message to a new delivery time. Same rules as scheduling one.
  public func rescheduleMessage(chatGUID: String, messageGUID: String, to date: Date) async throws {
    let api = try requirePrivateAPI(for: "Send Later")
    try Self.checkScheduledSend(date)
    try await requireMessage(messageGUID)
    try await throughMessages {
      try await api.rescheduleMessage(
        MessageGUID(messageGUID), in: ChatIdentifier(chatGUID), to: date)
    }
  }

  /// Rewrites a scheduled message's text before it is sent. Nothing is delivered until its
  /// time, so this leaves no edit history — unlike `edit`, which amends a sent message.
  public func editScheduledMessage(
    chatGUID: String, messageGUID: String, partIndex: Int = 0, newText: String
  ) async throws {
    let api = try requirePrivateAPI(for: "Send Later")
    guard !newText.isEmpty else {
      throw InterfaceError.invalidRequest("`message` must not be empty")
    }
    try await requireMessage(messageGUID)
    try await throughMessages {
      try await api.editScheduledMessage(
        MessageGUID(messageGUID), in: ChatIdentifier(chatGUID), partIndex: partIndex,
        newText: newText)
    }
  }

  /// Releases a scheduled message now. The row stops being pending and is delivered.
  public func sendScheduledMessageNow(chatGUID: String, messageGUID: String) async throws {
    let api = try requirePrivateAPI(for: "Send Later")
    try await requireMessage(messageGUID)
    try await throughMessages {
      try await api.sendScheduledMessageNow(
        MessageGUID(messageGUID), in: ChatIdentifier(chatGUID))
    }
  }

  /// Emoji reactions arrived with macOS 15 / iOS 18 and are refused below it, before the
  /// helper is asked: Sonoma has neither `IMEmojiTapback` nor `IMTapbackSender`, and the
  /// fallback send path there cannot carry an emoji. Same shape as the text-formatting gate.
  static func checkEmojiReactionSupported(
    majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  ) throws {
    guard majorVersion >= PrivateAPICapability.emojiReactions.minimumMacOS else {
      throw InterfaceError.invalidRequest(
        "Emoji reactions are only supported on macOS Sequoia (15) and newer"
      )
    }
  }

  /// The reference's two gates on `textFormatting`, then its range rules.
  ///
  /// macOS 15 is where the attributes appeared; the reference refuses below it with this
  /// sentence, and so does this. Ranges are checked against the UTF-16 length, because
  /// that is the unit the attributes are applied in.
  static func checkFormatting(_ ranges: [FormattedRange], text: String) throws {
    guard !ranges.isEmpty else { return }
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion
      < PrivateAPICapability.textFormatting.minimumMacOS
    {
      throw InterfaceError.invalidRequest(
        "Text formatting is only supported on macOS Sequoia (15) and newer"
      )
    }
    do {
      try FormattedRange.validate(ranges, utf16Length: text.utf16.count)
    } catch let error as TextFormattingError {
      throw InterfaceError.invalidRequest(error.description)
    }
  }

  /// The row behind a GUID, or the reference's refusal.
  ///
  /// `invalidRequest` — a 400 — and not `notFound`. It reads wrong and it is what ships: the
  /// reference's message-action routes all open with
  /// `if (!message) throw new BadRequest({ error: "Selected message does not exist!" })`.
  @discardableResult
  func requireMessage(_ guid: String) async throws -> IMessageRow {
    guard let row = try await repository.message(guid: guid) else {
      throw InterfaceError.invalidRequest(ReferenceMessages.selectedMessageMissing)
    }
    return row
  }

  /// Edits a message and answers with the edited row.
  ///
  /// The wait is different in kind from a send's. Nothing new appears — an existing row is
  /// MUTATED — so waiting for it to exist would return immediately with the message as it
  /// was before the edit, which is the pre-edit text a client would then display as though
  /// the edit had failed. What it waits for is `dateEdited` moving past what it was, which
  /// is exactly the reference's `extraLoopCondition`.
  public func edit(
    guid: String,
    partIndex: Int,
    newText: String,
    backwardCompatibilityText: String
  ) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "editing a message")
    // Message first, then its chat — the two refusals are different sentences in the
    // reference and this is the order that makes them mean what they say.
    //
    // Read BEFORE the edit. A message edited twice already has a `dateEdited`, so
    // "is it set" is not the question — "is it later than it was" is.
    let previousEdit = try await requireMessage(guid).dateEdited
    let chat = try await owningChat(of: guid)

    try await throughMessages {
      try await api.editMessage(
        MessageGUID(guid), in: chat, partIndex: partIndex,
        newText: newText, backwardCompatibilityText: backwardCompatibilityText
      )
    }
    return try await mutated(guid: guid, past: previousEdit)
  }

  /// The chat a message belongs to, from chat.db.
  ///
  /// The route carries only the message GUID, and the helper cannot fill the gap: an
  /// `IMMessageItem` fetched by GUID reports `chatIdentifier = nil`, so there is nothing on
  /// the message itself to resolve a conversation from. The database has the join, so the
  /// lookup belongs here.
  ///
  /// A message in more than one chat takes the first; that only happens for rows the
  /// database has duplicated, and either answer names the same conversation.
  private func owningChat(of messageGUID: String) async throws -> ChatIdentifier {
    let chats = try await repository.chats(forMessageGUID: messageGUID)
    guard let guid = chats.first?.guid else {
      // "Associated chat not found!", not "does not exist" — the reference reports the two
      // separately, and they mean different things to whoever is reading the error: a GUID
      // that names nothing, versus a message that is real and belongs to no conversation.
      // Callers check the message FIRST so this one only ever means the second.
      throw InterfaceError.invalidRequest(ReferenceMessages.associatedChatMissing)
    }
    return ChatIdentifier(guid)
  }

  /// Unsends a message and answers with the retracted row.
  ///
  /// Watches `dateEdited`, not `dateRetracted`, which looks like a mistake and is not: an
  /// unsend is recorded as an edit that empties the part, so `date_edited` is the column
  /// Messages moves. The reference watches the same one, and watching `dateRetracted`
  /// instead would wait out the full timeout on every successful unsend.
  public func unsend(guid: String, partIndex: Int) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "unsending a message")
    let previousEdit = try await requireMessage(guid).dateEdited
    let chat = try await owningChat(of: guid)

    try await throughMessages {
      try await api.unsendMessage(MessageGUID(guid), in: chat, partIndex: partIndex)
    }
    return try await mutated(guid: guid, past: previousEdit)
  }

  /// Rings a silenced message through, and answers with the notified row.
  ///
  /// Refused when the recipient has already been notified: the reference checks
  /// `didNotifyRecipient` before calling Messages, because the flag is what the wait below
  /// keys on — asking twice would leave it already true and answer instantly with a
  /// notification that never went out.
  public func notify(guid: String) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "notify anyway")
    let row = try await requireMessage(guid)
    guard row.didNotifyRecipient != true else {
      throw InterfaceError.invalidRequest(
        "The recipient has already been notified of this message!")
    }

    let chat = try await owningChat(of: guid)
    try await throughMessages {
      try await api.notifyAnyways(MessageGUID(guid), in: chat)
    }

    let notified = try await poll(policy: .mutation) {
      let projection = try await self.find(guid: guid, query: Self.sendQuery)
      return projection?.row.didNotifyRecipient == true ? projection : nil
    }
    return SendOutcome(backend: .privateAPI, messageGUID: guid, message: notified)
  }

  /// Waits for a row's `dateEdited` to move past what it was, then loads it.
  ///
  /// Nil on timeout, like a send's hydration and for the same reason: the edit was accepted
  /// by Messages, and answering 500 would tell a client its edit failed when it did not.
  func mutated(guid: String, past previous: AppleTimestamp?) async throws -> SendOutcome {
    // Compared as RAW values, with unset counting as zero — the reference's
    // `(data?.dateEdited ?? 0) <= currentEditDate`. Both readings come from the same
    // database in the same unit, so this is exact, and it sidesteps the fact that
    // `AppleTimestamp.date` is optional precisely because zero means "never" rather than
    // 2001-01-01.
    let before = previous?.rawValue ?? 0
    let edited = try await poll(policy: .mutation) {
      guard let projection = try await self.find(guid: guid, query: Self.sendQuery) else {
        return nil
      }
      return (projection.row.dateEdited?.rawValue ?? 0) > before ? projection : nil
    }
    return SendOutcome(backend: .privateAPI, messageGUID: guid, message: edited)
  }

  public func embeddedMediaPath(guid: String) async throws -> String {
    let api = try requirePrivateAPI(for: "embedded media")
    return try await throughMessages {
      try await api.balloonBundleMediaPath(for: MessageGUID(guid))
    }
  }
}
