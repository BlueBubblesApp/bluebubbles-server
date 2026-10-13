//  NotificationHintSourceTests
//  The notification hints are read from what the serializer actually writes.
//
//  `reference-v2` and `sealed-v2` read a message's GUID, chat, sender and text back out of
//  the serialized notification payload, and the keys they read are the constants the
//  serializer writes with (`MessageWireKey`). The codec suites check the readers against
//  hand-built JSON, which would keep passing if the serializer and the reader drifted apart:
//  both sides of such a test are written by the same hand. This one feeds the readers a real
//  `new-message` event built by the change detector from the chat.db fixture, so a key the
//  serializer stops writing blanks a hint HERE rather than on a phone.

import BBEvents
import BBIMessage
import BBPersistence
import BBSerialization
import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Notification hints from a real event", .removingChatDBCopies)
struct NotificationHintSourceTests {

  private func incomingEvent() async throws -> (ServerEvent, IMessageRow) {
    let fixture = try await MessageEventFixture()
    let row = try #require(
      try await fixture.repository.message(guid: MessageEventFixture.incomingGUID),
      "the fixture should hold the incoming message")
    var hydrator = EventHydrator(repository: fixture.repository)
    let event = try #require(
      await ChangeDetectionService.event(
        for: MessageChange(message: row, isNew: true, changedFields: []),
        serializer: fixture.serializer,
        hydrator: &hydrator
      ))
    return (event, row)
  }

  @Test("reference-v2 carries the message's GUID, chat, sender and preview")
  func referenceHints() async throws {
    let (event, row) = try await incomingEvent()
    let encoded = try await ReferencePayloadCodec(hint: .senderAndPreview).encode(
      event, projection: .notification, capabilities: .legacy)

    #expect(encoded.body["g"]?.stringValue == row.guid)
    #expect(encoded.body["c"]?.stringValue?.isEmpty == false)
    #expect(encoded.body["s"]?.stringValue?.isEmpty == false)
    #expect(encoded.body["p"]?.stringValue?.isEmpty == false)
  }

  @Test("sealed-v2's clear-text header carries the same sender and preview")
  func sealedHints() async throws {
    let (event, _) = try await incomingEvent()
    // Any 32 bytes are an X25519 public key; u = 9 is the curve's base point. Nothing here
    // decrypts, so no private half is needed.
    let devicePublicKey = Data([9] + Array(repeating: 0, count: 31))
    let sealed = try await SealedPayloadCodec(hint: .senderAndPreview).encode(
      event, projection: .notification,
      capabilities: TargetCapabilities(supportedCodecs: [.sealedV2], publicKey: devicePublicKey))
    let reference = try await ReferencePayloadCodec(hint: .senderAndPreview).encode(
      event, projection: .notification, capabilities: .legacy)

    #expect(sealed.body["s"] != nil)
    #expect(sealed.body["s"] == reference.body["s"])
    #expect(sealed.body["p"] == reference.body["p"])
  }
}
