//  EventHydrator
//  Loads what an event payload needs, once per batch.
//
//  `ChangeDetectionService` built both payloads from an empty `MessageSerializer.Context()`,
//  so every event this server emitted — socket, push and webhook alike — carried
//  `chats: []`, `handle: null` and `attachments: []`. Nothing downstream filled them in.
//
//  That is not cosmetic. The client reads `payload.data['chats'].first` UNCONDITIONALLY when
//  it handles `new-message` and `updated-message` (`action_handler.dart`), so an empty array
//  throws in its handler. It also left the FCM size cap with nothing to trim, which is why
//  that cap had never once fired.
//
//  ## Why the cache is per BATCH and not per service
//
//  A cache that lived as long as the pump would go stale: someone joins a group and every
//  later notification names the old roster. The reference keeps a `chatCache` inside a single
//  `serializeList` call for exactly this reason — long enough to collapse a burst, short
//  enough that it cannot be wrong. A batch from the detector is the same unit of work.

import BBIMessage
import BBSerialization
import Foundation

/// Builds serializer contexts for one batch of detected changes.
struct EventHydrator {

  private let repository: MessageRepository
  /// Chat GUID to its participants. See the header: this lives for one batch.
  private var participantsByChatGUID: [String: [HandleRow]] = [:]

  init(repository: MessageRepository) {
    self.repository = repository
  }

  /// The relations behind one message.
  ///
  /// Participants are loaded only when asked for, because the two projections differ: the
  /// notification payload carries them and the socket payload does not — see
  /// `MessageSerializerConfig.notification`, and the reference's two emit calls.
  mutating func context(
    for message: IMessageRow, withParticipants: Bool
  ) async -> MessageSerializer.Context {
    var context = MessageSerializer.Context()

    // Failures are swallowed per relation rather than dropping the event. A message whose
    // chat lookup fails is still worth announcing with the fields that did load — the
    // alternative is silence, and a client that never hears about a message it can see in
    // Messages.app has no way to recover.
    context.chats = (try? await repository.chats(forMessageGUID: message.guid)) ?? []
    context.attachments =
      (try? await repository.attachments(forMessageGUID: message.guid)) ?? []
    if let handleID = message.handleID {
      context.handle = try? await repository.handle(rowID: handleID)
    }

    guard withParticipants else { return context }
    for chat in context.chats {
      if let cached = participantsByChatGUID[chat.guid] {
        context.participantsByChatGUID[chat.guid] = cached
        continue
      }
      let loaded = (try? await repository.participants(chatGUID: chat.guid)) ?? []
      participantsByChatGUID[chat.guid] = loaded
      context.participantsByChatGUID[chat.guid] = loaded
    }
    return context
  }
}
