//  EventHydrator
//  Loads what an event payload needs, once per batch.
//
//  An event payload built from an empty `MessageSerializer.Context()` carries `chats: []`,
//  `handle: null` and `attachments: []`, and nothing downstream fills them in.
//
//  That is not cosmetic. The client reads `payload.data['chats'].first` UNCONDITIONALLY when
//  it handles `new-message` and `updated-message` in its action handler, so an empty array
//  throws in its handler.
//
//  ## Why the cache is per BATCH and not per service
//
//  A cache that lived as long as the pump would go stale: someone joins a group and every
//  later notification names the old roster. The reference keeps a `chatCache` inside a single
//  `serializeList` call for exactly this reason: long enough to collapse a burst, short
//  enough that it cannot be wrong. A batch from the detector is the same unit of work.

import BBCore
import BBIMessage
import BBSerialization
import Foundation
import Logging

/// Builds serializer contexts for one batch of detected changes.
struct EventHydrator {

  private let repository: MessageRepository
  /// What is read off disk about each attachment (`hasLivePhoto`). Unlike the participants
  /// below this may outlive the batch: a finished transfer's answer cannot go stale.
  private let files: AttachmentMetadataReader
  private let logger: Logger
  /// Chat GUID to its participants. See the header: this lives for one batch.
  private var participantsByChatGUID: [String: [HandleRow]] = [:]

  init(
    repository: MessageRepository,
    files: AttachmentMetadataReader = AttachmentMetadataReader(),
    logger: Logger = Logger(label: "bluebubbles.change-detector")
  ) {
    self.repository = repository
    self.files = files
    self.logger = logger
  }

  /// The relations behind one message.
  ///
  /// Participants are loaded only when asked for, because the two projections differ: the
  /// notification payload carries them and the socket payload does not; see
  /// `MessageSerializerConfig.notification`, and the reference's two emit calls.
  ///
  /// Nil when the message has no chat to name, and then there is no event to send. The client
  /// throws on `chats: []`, so sending one tells it nothing, and the reference's poll never
  /// returns a message without a chat. The detector holds a message until its chat row exists
  /// (`ChangeDetector.HeldArrivals`), so getting here takes a read that failed just after that
  /// one succeeded, or a join naming a chat that is gone. The row stays on disk for a sync.
  ///
  /// Every other relation is logged and swallowed rather than dropping the event: a message
  /// with no handle or attachments is still one a client can file.
  mutating func context(
    for message: IMessageRow, withParticipants: Bool
  ) async -> MessageSerializer.Context? {
    var context = MessageSerializer.Context()

    guard
      let chats = await loaded(
        "chats", of: message.guid, level: .warning,
        {
          try await repository.chats(forMessageGUID: message.guid)
        }), !chats.isEmpty
    else {
      // A warning, because this is a message no client is told about.
      logger.warning(
        "A message has no chat to name; its event is not sent",
        metadata: ["guid": .string(message.guid)])
      return nil
    }
    context.chats = chats
    // Metadata is not read here and never was, so an event's attachment answers `height: 0,
    // width: 0`. Reading it would change the wire, and is a decision of its own.
    await context.load(
      attachments: await loaded("attachments", of: message.guid) {
        try await repository.attachments(forMessageGUID: message.guid)
      } ?? [],
      from: files, withMetadata: false)
    if let handleID = message.handleID {
      // The repository's answer is itself optional, so the failure wrapper adds a layer.
      context.handle =
        await loaded("handle", of: message.guid) {
          try await repository.handle(rowID: handleID)
        } ?? nil
    }

    guard withParticipants else { return context }
    for chat in context.chats {
      if let cached = participantsByChatGUID[chat.guid] {
        context.participantsByChatGUID[chat.guid] = cached
        continue
      }
      let loaded =
        await loaded("participants", of: message.guid, chat: chat.guid) {
          try await repository.participants(chatGUID: chat.guid)
        } ?? []
      participantsByChatGUID[chat.guid] = loaded
      context.participantsByChatGUID[chat.guid] = loaded
    }
    return context
  }

  /// One relation, or nil with the failure logged. The chat, when there is one, is
  /// redacted: a direct chat's GUID is the other party's address.
  private func loaded<T>(
    _ relation: String, of guid: String, chat: String? = nil, level: Logger.Level = .debug,
    _ load: () async throws -> T
  ) async -> T? {
    do {
      return try await load()
    } catch {
      logger.log(
        level: level,
        "Could not load a message relation",
        metadata: [
          "relation": .string(relation),
          "guid": .string(guid),
          "chat": .string(chat.map(Redaction.chatGUID) ?? "-"),
          "error": .string(String(describing: error)),
        ])
      return nil
    }
  }
}
