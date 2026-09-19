//  UpdateNotificationShapeTests
//  An update's PUSH drops the chat; an update's SOCKET must not.
//
//  The reference splits `updated-message` into two emits with two configs (`index.ts:1576`
//  and `:1590`): the socket gets `loadChatParticipants: false, includeChats: true`, and the
//  FCM emit gets both false, under the comment "Since this is a message update, we do not
//  need to include the participants or chats". We sent one shape to both, so every edit,
//  unsend, reaction and read receipt pushed a chat object and its full roster — which is
//  exactly what `FCMSender` then has to shed against Google's 4 KB cap.
//
//  **The socket half is the dangerous one to get wrong, and the audit proposed getting it
//  wrong.** Its suggestion was to drop chats from "the updated-message and send-error
//  events" without distinguishing transport. The Flutter client's updated-message branch
//  reads `payload.data['chats'].first` with NO null guard — `attachments` on the very next
//  line uses `?? const []`, so the asymmetry is deliberate — and an updated-message with no
//  chat throws inside the handler. Dropping it from the socket would have broken every
//  Android and desktop client on edits, unsends and read receipts.
//
//  send-error is a THIRD shape, not a second one. The reference serializes it once for both
//  transports with `{ loadChatParticipants: false }` alone, so `includeChats` inherits
//  `true`: a client that has just failed to send still needs to know which conversation
//  failed.

import BBEvents
import BBIMessage
import BBSerialization
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Update notification shape")
struct UpdateNotificationShapeTests {

  @Test("The socket shape keeps chats for every message event")
  func socketAlwaysCarriesChats() {
    // The client-breaking direction. `.full` is what every socket emit uses.
    #expect(MessageSerializerConfig.full.includeChats)
    #expect(!MessageSerializerConfig.full.loadChatParticipants)
  }

  @Test("An update's notification carries neither chats nor participants")
  func updateNotificationIsBare() {
    #expect(!MessageSerializerConfig.notificationUpdate.includeChats)
    #expect(!MessageSerializerConfig.notificationUpdate.loadChatParticipants)
  }

  @Test("A send error's notification keeps chats and drops participants")
  func sendErrorKeepsChats() {
    // The one that reads like an inconsistency in the reference and is not: its comment
    // says only "we don't need to include the participants".
    #expect(MessageSerializerConfig.notificationSendError.includeChats)
    #expect(!MessageSerializerConfig.notificationSendError.loadChatParticipants)
  }

  @Test("A new message's notification is the only one that loads participants")
  func newMessageNotificationIsUnchanged() {
    // Pinned so the saving above cannot be taken further by mistake: a push for a group
    // chat carries the roster, and it is also what `FCMSender` sheds when a payload is over
    // 4 KB. With participants never loaded there would be nothing to shed.
    #expect(MessageSerializerConfig.notification.loadChatParticipants)
    #expect(MessageSerializerConfig.notification.includeChats)
  }

  @Test("The three notification shapes are actually three")
  func theShapesAreDistinct() {
    // The audit read `updated-message` and `send-error` as one case. They differ on chats,
    // and `new-message` differs from both on participants, so collapsing any pair silently
    // reintroduces one of the two divergences.
    let shapes = [
      MessageSerializerConfig.notification,
      MessageSerializerConfig.notificationUpdate,
      MessageSerializerConfig.notificationSendError,
    ].map { [$0.includeChats, $0.loadChatParticipants] }

    #expect(Set(shapes.map { "\($0)" }).count == 3, "three events, three shapes: \(shapes)")
  }

  // MARK: - What the builder actually emits

  /// The real builder, against a real `chat.db`. The constants above are the intent; this is
  /// whether the intent is wired to anything. `MessageEventFixture` owns the copy and the
  /// `failing` write — see its header for why that is not left to the caller.
  private func event(
    guid: String, isNew: Bool, changedFields: Set<MessageField> = [],
    failing: Bool = false
  ) async throws -> ServerEvent {
    let fixture = try await MessageEventFixture(
      named: "updshape", failing: failing ? guid : nil)
    var hydrator = EventHydrator(repository: fixture.repository)
    let row = try #require(try await fixture.repository.message(guid: guid))
    return try #require(
      await ChangeDetectionService.event(
        for: MessageChange(message: row, isNew: isNew, changedFields: changedFields),
        serializer: fixture.serializer,
        hydrator: &hydrator))
  }

  private func hasChats(_ payload: JSONValue) -> Bool {
    guard case .object(let fields) = payload, case .array(let chats) = fields["chats"]
    else { return false }
    return !chats.isEmpty
  }

  @Test("An update's socket payload still carries a chat, and its push does not")
  func updateSplitsByTransport() async throws {
    // The whole finding in one assertion pair. Both halves matter and they point opposite
    // ways: dropping it from the push is the fix, dropping it from the socket is an outage.
    let event = try await event(
      guid: MessageEventFixture.incomingGUID, isNew: false, changedFields: [.read])

    #expect(event.name == .updatedMessage)
    #expect(hasChats(event.fullPayload), "the socket payload must keep its chat")
    #expect(!hasChats(event.notificationPayload), "the push must not carry a chat")
  }

  @Test("A new message carries a chat on both")
  func newMessageCarriesChatsEverywhere() async throws {
    // The control. If this ever goes the way of the update, a push stops saying which
    // conversation a message arrived in, which is most of what a notification is for.
    let event = try await event(guid: MessageEventFixture.incomingGUID, isNew: true)

    #expect(event.name == .newMessage)
    #expect(hasChats(event.fullPayload))
    #expect(hasChats(event.notificationPayload))
  }

  @Test("A send error carries a chat on both")
  func sendErrorCarriesChatsEverywhere() async throws {
    let event = try await event(
      guid: MessageEventFixture.outgoingGUID, isNew: false, changedFields: [.error], failing: true)

    #expect(event.name == .messageSendError)
    #expect(hasChats(event.notificationPayload), "a failed send must name the conversation")
  }
}
