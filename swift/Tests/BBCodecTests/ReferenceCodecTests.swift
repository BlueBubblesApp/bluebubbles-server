//  ReferenceCodecTests
//  reference-v2: what travels, and what deliberately does not.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBSerialization
import Crypto
import Foundation
import Testing

@testable import BBEvents

private func message(
  text: String = "Hello there",
  isFromMe: Bool = false
) -> ServerEvent {
  ServerEvent(
    name: .newMessage,
    fullPayload: .object([
      "guid": .string("A1B2C3D4-0000-0000-0000-000000000001"),
      "text": .string(text),
      "isFromMe": .bool(isFromMe),
      "handle": .object(["address": .string("+12025550143")]),
      "chats": .array([.object(["guid": .string("iMessage;-;+12025550143")])]),
    ]),
    occurredAt: Date(timeIntervalSince1970: 1_740_000_000)
  )
}

@Suite("Reference envelope")
struct ReferenceEnvelopeTests {

  /// `{"v":2,"t":"new-message","g":"…","c":"…","ts":…}` — small on purpose, because it has
  /// to fit inside FCM's 4KB data limit with room to spare.
  @Test("The envelope carries identifiers and a timestamp")
  func envelopeShape() async throws {
    let encoded = try await ReferencePayloadCodec().encode(
      message(), projection: .notification, capabilities: .legacy
    )
    let body = encoded.body

    #expect(body["v"]?.intValue == 2)
    #expect(body["t"]?.stringValue == "new-message")
    #expect(body["g"]?.stringValue == "A1B2C3D4-0000-0000-0000-000000000001")
    #expect(body["c"]?.stringValue == "iMessage;-;+12025550143")
    #expect(body["ts"] != nil)
  }

  /// The whole point: message content never transits Google's infrastructure, so there is
  /// no key management problem to get wrong.
  @Test("No message body travels by default")
  func noBodyByDefault() async throws {
    let encoded = try await ReferencePayloadCodec().encode(
      message(text: "a private message"), projection: .notification, capabilities: .legacy
    )
    let serialized = String(decoding: try encoded.body.serialize(), as: UTF8.self)

    #expect(!serialized.contains("a private message"))
    // The sender hint is off by default, so it is absent as a FIELD.
    #expect(encoded.body["s"] == nil)
    #expect(encoded.body["p"] == nil)
  }

  /// An honest limit, asserted rather than glossed: **reference-v2 hides message content,
  /// not metadata.** A chat GUID IS the counterparty's address — `iMessage;-;+1…` — and the
  /// client needs it to route the notification, so it cannot be withheld. Anyone who can
  /// read the push payload learns who you are talking to and when, just not what was said.
  ///
  /// Hiding that too is what `sealed-v2` is for: there the whole body, chat GUID included,
  /// is inside the ciphertext.
  @Test("The chat GUID necessarily reveals the counterparty")
  func chatGUIDIsMetadataNotContent() async throws {
    let encoded = try await ReferencePayloadCodec().encode(
      message(), projection: .notification, capabilities: .legacy
    )
    // Stated as a fact of the design, so a future change to hide it is a deliberate
    // decision rather than an accident.
    #expect(encoded.body["c"]?.stringValue == "iMessage;-;+12025550143")

    // sealed-v2, by contrast, leaks neither.
    let device = Curve25519.KeyAgreement.PrivateKey()
    let sealed = try await SealedPayloadCodec().encode(
      message(),
      projection: .notification,
      capabilities: TargetCapabilities(
        supportedCodecs: [.sealedV2], publicKey: device.publicKey.rawRepresentation
      )
    )
    let sealedText = String(decoding: try sealed.body.serialize(), as: UTF8.self)
    #expect(!sealedText.contains("+12025550143"))
  }

  /// The envelope must stay far inside the FCM ceiling — that headroom is one of the
  /// reasons for the codec, since today's serializer strips chat participants to fit.
  @Test("The envelope is small enough that the FCM limit stops mattering")
  func envelopeIsSmall() async throws {
    let encoded = try await ReferencePayloadCodec().encode(
      message(), projection: .notification, capabilities: .legacy
    )
    let size = try encoded.body.serialize().count
    #expect(size < 256, "expected a tiny envelope, got \(size) bytes")
  }

  /// An event with no message must not emit `"g": null` — that would make every client
  /// handle a case that never means anything.
  @Test("Absent identifiers are omitted rather than nulled")
  func absentIdentifiersOmitted() async throws {
    let serverEvent = ServerEvent(
      name: .serverUpdate, fullPayload: .object(["version": .string("1.2.3")])
    )
    let encoded = try await ReferencePayloadCodec().encode(
      serverEvent, projection: .notification, capabilities: .legacy
    )
    #expect(!encoded.body.objectKeys.contains("g"))
    #expect(!encoded.body.objectKeys.contains("c"))
    #expect(encoded.body["t"]?.stringValue == "server-update")
  }
}

@Suite("Reference hints")
struct ReferenceHintTests {

  /// The user's privacy decision, not ours — so the default reveals nothing.
  @Test("Hints are off by default")
  func hintsOffByDefault() async throws {
    let encoded = try await ReferencePayloadCodec().encode(
      message(), projection: .notification, capabilities: .legacy
    )
    #expect(encoded.body["s"] == nil)
    #expect(encoded.body["p"] == nil)
  }

  /// Enough for "Message from …" without the message.
  @Test("senderOnly adds the sender and not the text")
  func senderOnly() async throws {
    let encoded = try await ReferencePayloadCodec(hint: .senderOnly).encode(
      message(text: "still private"), projection: .notification, capabilities: .legacy
    )
    #expect(encoded.body["s"]?.stringValue == "+12025550143")
    #expect(encoded.body["p"] == nil)

    let serialized = String(decoding: try encoded.body.serialize(), as: UTF8.self)
    #expect(!serialized.contains("still private"))
  }

  @Test("senderAndPreview adds a truncated preview")
  func senderAndPreview() async throws {
    let encoded = try await ReferencePayloadCodec(hint: .senderAndPreview).encode(
      message(text: "Hello there"), projection: .notification, capabilities: .legacy
    )
    #expect(encoded.body["s"]?.stringValue == "+12025550143")
    #expect(encoded.body["p"]?.stringValue == "Hello there")
  }

  /// A preview is a hint. A long one is just the message with extra steps.
  @Test("A long preview is truncated")
  func previewTruncates() async throws {
    let long = String(repeating: "word ", count: 100)
    let encoded = try await ReferencePayloadCodec(hint: .senderAndPreview).encode(
      message(text: long), projection: .notification, capabilities: .legacy
    )
    let preview = try #require(encoded.body["p"]?.stringValue)
    #expect(preview.count <= ReferencePayloadCodec.maximumPreviewLength + 1)
    #expect(preview.hasSuffix("…"))
  }

  /// Truncation must not split a grapheme — half an emoji is a rendering bug on the client.
  @Test("Truncation respects character boundaries")
  func truncationIsGraphemeSafe() throws {
    let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 40)
    let preview = try #require(
      ReferencePayloadCodec.preview(in: .object(["text": .string(emoji)])),
      "a text payload always previews"
    )
    // Round-trips as valid UTF-8, which a split grapheme would not.
    #expect(String(decoding: Data(preview.utf8), as: UTF8.self) == preview)
  }

  /// The address, not a resolved contact name. Resolving here would put a name out of the
  /// user's address book into a push payload — a bigger disclosure than the address the
  /// message already came from.
  @Test("An outgoing message has no sender hint")
  func outgoingHasNoSender() async throws {
    let encoded = try await ReferencePayloadCodec(hint: .senderOnly).encode(
      message(isFromMe: true), projection: .notification, capabilities: .legacy
    )
    #expect(encoded.body["s"] == nil)
  }

  @Test("An empty message yields no preview")
  func emptyTextHasNoPreview() {
    #expect(ReferencePayloadCodec.preview(in: .object(["text": .string("   ")])) == nil)
    #expect(ReferencePayloadCodec.preview(in: .object([:])) == nil)
  }
}

@Suite("Hydration requests")
struct HydrationTests {

  @Test("A request decodes with its optional field defaulted")
  func decoding() throws {
    let request = try JSONDecoder().decode(
      HydrationRequest.self, from: Data(#"{"guids":["A1","B2"]}"#.utf8)
    )
    #expect(request.guids == ["A1", "B2"])
    #expect(!request.withAttachments)
  }

  /// Batched because notifications arrive in bursts — a group chat waking up produces a
  /// dozen at once, and a dozen round trips on a phone radio is a real cost.
  @Test("Duplicates are collapsed, preserving order")
  func deduplicates() {
    let request = HydrationRequest(guids: ["A1", "B2", "A1", "C3", "B2"])
    #expect(request.uniqueGUIDs == ["A1", "B2", "C3"])
  }

  /// A client asking for ten thousand guids is either broken or probing.
  @Test("An oversized batch is refused")
  func rejectsOversizedBatch() {
    let tooMany = (0..<(HydrationRequest.maximumGUIDs + 1)).map { "guid-\($0)" }
    #expect(throws: HydrationRequest.ValidationError.self) {
      try HydrationRequest(guids: tooMany).validate()
    }
    #expect(throws: HydrationRequest.ValidationError.empty) {
      try HydrationRequest(guids: []).validate()
    }
  }

  @Test("A batch at the limit is accepted")
  func acceptsBatchAtLimit() throws {
    let atLimit = (0..<HydrationRequest.maximumGUIDs).map { "guid-\($0)" }
    #expect(throws: Never.self) { try HydrationRequest(guids: atLimit).validate() }
  }
}
