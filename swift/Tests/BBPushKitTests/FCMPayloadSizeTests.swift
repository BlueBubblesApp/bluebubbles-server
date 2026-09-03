//  FCMPayloadSizeTests
//  The 4 KB ceiling, tested where it now lives.
//
//  It used to live in `MessageSerializer` as `enforceMaxSize`, applied to a projection that
//  FCM, webhooks and ntfy all consumed — so one transport's constraint, set by Google, was
//  imposed on transports that do not share it. ntfy's limit is whatever the operator
//  configured; a UnifiedPush distributor's is invisible from this server; a webhook has none.
//
//  Two things improved by moving it here beyond the layering:
//
//  - It measures what Google actually weighs — the whole `data` map, keys and JSON-string
//    escaping included — rather than the message object plus two bytes for brackets, which
//    is what the serializer measured while guessing at a wrapper it could not see.
//  - It TRIMS and sends, where the old code in this file measured and refused every token.
//
//  The old suite lived in `MessageSerializerTests` as "Notification size ceiling", and it
//  passed while the shipping configuration was broken: it built its own config with
//  `loadChatParticipants: true`, noting in a comment that this was "the only combination
//  where the cap can do anything", while `.notification` shipped with it false — so in
//  production there was never anything to drop and the cap had never once fired.

import Foundation
import Testing

@testable import BBPushKit

@Suite("FCM payload size")
struct FCMPayloadSizeTests {

  /// A `{type, data}` map shaped like the real thing: `data` is a JSON STRING, because FCM
  /// data payloads are string-to-string maps.
  private func payload(text: String, participants: Int) -> [String: String] {
    let roster = (0..<participants).map { index in
      ["address": "+1202555\(String(format: "%04d", index))", "service": "iMessage"]
    }
    let message: [String: Any] = [
      "guid": "E1B2C3D4-0000-0000-0000-000000000001",
      "text": text,
      "chats": [["guid": "iMessage;-;+12025550143", "participants": roster]],
    ]
    let encoded = try! JSONSerialization.data(withJSONObject: message)
    return ["type": "new-message", "data": String(data: encoded, encoding: .utf8)!]
  }

  private func participantCount(in data: [String: String]) -> Int {
    guard let raw = data["data"],
      let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
      let chats = object["chats"] as? [[String: Any]]
    else { return -1 }
    return (chats.first?["participants"] as? [Any])?.count ?? 0
  }

  /// The common case: under budget, so `send` never reaches the trim. Asserted as the GATE
  /// rather than by calling `trimmed`, which sheds unconditionally by design — it is "drop
  /// the roster", not "drop it if needed", and the size decision belongs to the one caller.
  ///
  /// This is what stops the trim from being effectively always-on, which would strip
  /// participants from every notification and undo the reason they are loaded at all.
  @Test("A payload under the limit never reaches the trim")
  func smallPayloadIsUntouched() {
    let data = payload(text: "hey", participants: 3)
    let size = try! #require(FCMSender.payloadSize(of: data))
    #expect(size < FCMSender.maximumPayloadBytes)
    // Untrimmed, it still carries its roster — so what a client receives is the full one.
    #expect(participantCount(in: data) == 3)
  }

  /// The regression the serializer-level cap was written for and could not catch in
  /// production: the TEXT is what blows the budget, not the roster.
  @Test("A long message is trimmed of its participants, keeping the chat")
  func longTextIsTrimmed() {
    let data = payload(text: String(repeating: "a", count: 5_000), participants: 3)
    #expect(FCMSender.payloadSize(of: data)! > FCMSender.maximumPayloadBytes)

    let trimmed = FCMSender.trimmed(data)
    #expect(participantCount(in: trimmed) == 0)
    // The chat itself survives — a notification still has to say which conversation it
    // belongs to. Only the roster goes.
    let object =
      try! JSONSerialization.jsonObject(
        with: Data(trimmed["data"]!.utf8)) as! [String: Any]
    #expect((object["chats"] as! [[String: Any]]).count == 1)
    #expect(object["text"] as? String == String(repeating: "a", count: 5_000))
  }

  @Test("A large roster on a short message is trimmed too")
  func manyParticipantsAreTrimmed() {
    let data = payload(text: "hey", participants: 200)
    #expect(FCMSender.payloadSize(of: data)! > FCMSender.maximumPayloadBytes)
    #expect(participantCount(in: FCMSender.trimmed(data)) == 0)
    #expect(FCMSender.payloadSize(of: FCMSender.trimmed(data))! < FCMSender.maximumPayloadBytes)
  }

  /// A payload it cannot parse is returned untouched rather than mangled. An oversized
  /// payload is a bad outcome; a corrupt one is a worse one, and the caller refuses an
  /// oversized payload a moment later anyway.
  @Test("An unparseable payload is left alone")
  func unparseablePayloadSurvives() {
    let data = ["type": "new-message", "data": "not json at all"]
    #expect(FCMSender.trimmed(data) == data)
    #expect(FCMSender.trimmed(["type": "hello-world"]) == ["type": "hello-world"])
  }

  /// The number is Google's and belongs to this file alone.
  @Test("The limit is FCM's, and nothing else declares one")
  func theLimitLivesHere() {
    #expect(FCMSender.maximumPayloadBytes == 4096)
  }
}
