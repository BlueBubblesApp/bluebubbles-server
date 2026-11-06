//  AppPayloadEventTests
//  An app balloon's events: the decoded payload on the socket, nothing new on a push.
//
//  `appPayload` is added to the chat.db watcher's FULL payload so a socket client can open a
//  Game Pigeon game without fetching the message again. The notification payload is the
//  one FCM carries, and FCM refuses anything over 4096 bytes, at which point `FCMSender`
//  sheds the chat roster to fit. An 8 Ball move's payload URL alone runs to kilobytes, so
//  letting the projection reach that shape would push exactly the messages it exists for
//  over the cap. That is the assertion below, on all three event names the watcher emits.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import BBEvents
import BBIMessage
import BBSerialization
import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("App payload on events", .removingChatDBCopies)
struct AppPayloadEventTests {

  private static let bundleID =
    "com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:"
    + GamePigeonCodec.extensionSuffix
  private static let session = "2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22"

  /// A Game Pigeon URL the size of a real move's: a long `replay` field is what makes one
  /// several kilobytes.
  private static var largeURL: String {
    GamePigeonCodec.encode(
      GamePigeonCodec.Payload(
        version: 45,
        fields: [
          (name: "game", value: "pool"),
          (name: "replay", value: String(repeating: "0.123456,", count: 600)),
        ]))
  }

  private func event(
    isNew: Bool, changedFields: Set<MessageField> = [], failing: Bool = false
  ) async throws -> ServerEvent {
    let guid = MessageEventFixture.incomingGUID
    let payload = try AppMessagePayload.encode(
      url: Self.largeURL, sessionID: try #require(UUID(uuidString: Self.session)),
      appName: "GamePigeon", appID: GamePigeonCodec.appStoreID, summary: "8 Ball",
      caption: "Your move.")
    let fixture = try await MessageEventFixture(
      failing: failing ? guid : nil,
      balloon: (guid: guid, bundleID: Self.bundleID, payload: payload))
    let row = try #require(try await fixture.repository.message(guid: guid))
    var hydrator = EventHydrator(repository: fixture.repository)
    return try #require(
      await ChangeDetectionService.event(
        for: MessageChange(message: row, isNew: isNew, changedFields: changedFields),
        serializer: fixture.serializer, hydrator: &hydrator))
  }

  @Test(
    "The socket gets appPayload and a push does not, on every event the watcher emits",
    arguments: [(true, false), (false, false), (false, true)])
  func socketOnly(isNew: Bool, failing: Bool) async throws {
    let event = try await event(
      isNew: isNew, changedFields: failing ? [.error] : [.delivered], failing: failing)
    let expected: EventName =
      failing ? .messageSendError : isNew ? .newMessage : .updatedMessage
    #expect(event.name == expected)

    #expect(event.fullPayload["appPayload"]?["session_id"]?.stringValue == Self.session)
    #expect(event.fullPayload["appPayload"]?["url"]?.stringValue == Self.largeURL)
    #expect(event.notificationPayload["appPayload"] == nil)
  }

  @Test("A push for a large app balloon stays under FCM's cap")
  func pushStaysSmall() async throws {
    let event = try await event(isNew: true)
    let data = try JSONSerialization.data(
      withJSONObject: event.notificationPayload.foundationObject, options: [])
    let full = try JSONSerialization.data(
      withJSONObject: event.fullPayload.foundationObject, options: [])

    // The point of the fixture: the socket's copy is over the cap, so a projection that
    // leaked into the push would fail here rather than in a phone that never rang.
    #expect(full.count > 4096)
    #expect(data.count < 4096, "the push payload was \(data.count) bytes")
  }
}
