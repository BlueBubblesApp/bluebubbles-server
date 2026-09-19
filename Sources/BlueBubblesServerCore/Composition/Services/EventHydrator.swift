//  EventHydrator
//  Loads what an event payload needs, once per batch.
//
//  An event payload built from an empty `MessageSerializer.Context()` carries `chats: []`,
//  `handle: null` and `attachments: []`, and nothing downstream fills them in.
//
//  That is not cosmetic. The client reads `payload.data['chats'].first` UNCONDITIONALLY when
//  it handles `new-message` and `updated-message` (`action_handler.dart`), so an empty array
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
  private let logger: Logger
  /// Chat GUID to its participants. See the header: this lives for one batch.
  private var participantsByChatGUID: [String: [HandleRow]] = [:]

  init(
    repository: MessageRepository,
    logger: Logger = Logger(label: "bluebubbles.change-detector")
  ) {
    self.repository = repository
    self.logger = logger
  }

  /// The relations behind one message.
  ///
  /// Participants are loaded only when asked for, because the two projections differ: the
  /// notification payload carries them and the socket payload does not; see
  /// `MessageSerializerConfig.notification`, and the reference's two emit calls.
  mutating func context(
    for message: IMessageRow, withParticipants: Bool
  ) async -> MessageSerializer.Context {
    var context = MessageSerializer.Context()

    // Failures are logged and swallowed per relation rather than dropping the event. A
    // message whose chat lookup fails is still worth announcing with the fields that did
    // load: the alternative is silence, and a client that never hears about a message it
    // can see in Messages.app has no way to recover. Logged, because `chats: []` on the
    // wire is indistinguishable from "no chats" and the client's handler throws on it.
    context.chats =
      await loaded("chats", of: message.guid) {
        try await repository.chats(forMessageGUID: message.guid)
      } ?? []
    context.attachments =
      await loaded("attachments", of: message.guid) {
        try await repository.attachments(forMessageGUID: message.guid)
      } ?? []
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
    _ relation: String, of guid: String, chat: String? = nil,
    _ load: () async throws -> T
  ) async -> T? {
    do {
      return try await load()
    } catch {
      logger.debug(
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
