//  SealedCodecTests
//  sealed-v2, verified by decrypting it.
//
//  A codec that only round-trips through its own encoder proves nothing — the same bug on
//  both sides cancels out. So these decrypt with a real X25519 keypair, and then check that
//  every way of tampering with the envelope fails closed.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBSerialization
import Crypto
import Foundation
import Testing

@testable import BBEvents

private func sampleEvent(
  name: EventName = .newMessage,
  text: String = "Hello there"
) -> ServerEvent {
  ServerEvent(
    name: name,
    fullPayload: .object([
      "guid": .string("A1B2C3D4-0000-0000-0000-000000000001"),
      "text": .string(text),
      "isFromMe": .bool(false),
      "handle": .object(["address": .string("+12025550143")]),
      "chats": .array([.object(["guid": .string("iMessage;-;+12025550143")])]),
    ]),
    occurredAt: Date(timeIntervalSince1970: 1_740_000_000)
  )
}

@Suite("Sealed payloads")
struct SealedCodecTests {

  /// The property the whole codec exists for.
  @Test("A sealed payload decrypts to the original")
  func roundTrips() async throws {
    let device = Curve25519.KeyAgreement.PrivateKey()
    let codec = SealedPayloadCodec()
    let event = sampleEvent()

    let encoded = try await codec.encode(
      event,
      projection: .full,
      capabilities: TargetCapabilities(
        supportedCodecs: [.sealedV2], publicKey: device.publicKey.rawRepresentation
      )
    )

    let opened = try SealedPayloadCodec.open(envelope: encoded.body, using: device)
    #expect(opened["guid"]?.stringValue == "A1B2C3D4-0000-0000-0000-000000000001")
    #expect(opened["text"]?.stringValue == "Hello there")
  }

  /// The envelope's plaintext half is what routes the notification, so its shape is a
  /// contract with the client.
  @Test("The envelope exposes routing metadata and nothing else")
  func envelopeShape() async throws {
    let device = Curve25519.KeyAgreement.PrivateKey()
    let encoded = try await SealedPayloadCodec().encode(
      sampleEvent(text: "a secret message"),
      projection: .full,
      capabilities: TargetCapabilities(
        supportedCodecs: [.sealedV2], publicKey: device.publicKey.rawRepresentation
      )
    )

    let body = encoded.body
    #expect(body["v"]?.intValue == 2)
    #expect(body["t"]?.stringValue == "new-message")
    #expect(body["alg"]?.stringValue == "x25519-chacha20poly1305")
    #expect(body["epk"]?.stringValue != nil)
    #expect(body["n"]?.stringValue != nil)
    #expect(body["ct"]?.stringValue != nil)

    // Nothing from the message leaks into the clear.
    let serialized = String(decoding: try body.serialize(), as: UTF8.self)
    #expect(!serialized.contains("a secret message"))
    #expect(!serialized.contains("+12025550143"))
    #expect(!serialized.contains("A1B2C3D4"))
  }

  /// Forward secrecy comes from the ephemeral key being fresh every time. If two messages
  /// shared one, compromising it would open both.
  @Test("Every message uses a fresh ephemeral key and nonce")
  func freshKeyPerMessage() async throws {
    let device = Curve25519.KeyAgreement.PrivateKey()
    let codec = SealedPayloadCodec()
    let capabilities = TargetCapabilities(
      supportedCodecs: [.sealedV2], publicKey: device.publicKey.rawRepresentation
    )

    var ephemeralKeys = Set<String>()
    var nonces = Set<String>()
    var ciphertexts = Set<String>()
    for _ in 0..<25 {
      let encoded = try await codec.encode(
        sampleEvent(), projection: .full, capabilities: capabilities
      )
      ephemeralKeys.insert(encoded.body["epk"]?.stringValue ?? "")
      nonces.insert(encoded.body["n"]?.stringValue ?? "")
      ciphertexts.insert(encoded.body["ct"]?.stringValue ?? "")
    }

    #expect(ephemeralKeys.count == 25)
    // Nonce reuse under ChaCha20 is catastrophic rather than merely bad.
    #expect(nonces.count == 25)
    // Identical plaintext must not produce identical ciphertext.
    #expect(ciphertexts.count == 25)
  }

  /// AEAD, not just encryption: a flipped bit in the body must be rejected, not decrypted
  /// into garbage the client then acts on.
  @Test("A tampered ciphertext is rejected")
  func tamperedCiphertextFails() async throws {
    let device = Curve25519.KeyAgreement.PrivateKey()
    let encoded = try await SealedPayloadCodec().encode(
      sampleEvent(),
      projection: .full,
      capabilities: TargetCapabilities(
        supportedCodecs: [.sealedV2], publicKey: device.publicKey.rawRepresentation
      )
    )

    guard case .object(var fields) = encoded.body,
      let original = fields["ct"]?.stringValue,
      var bytes = Data(base64Encoded: original)
    else {
      Issue.record("could not read the ciphertext")
      return
    }

    bytes[0] ^= 0x01
    fields["ct"] = .string(bytes.base64EncodedString())

    #expect(throws: (any Error).self) {
      _ = try SealedPayloadCodec.open(envelope: .object(fields), using: device)
    }
  }

  /// The reason the header is authenticated. Without binding it, an attacker could take a
  /// sealed typing-indicator and relabel it a new-message: the body would still decrypt,
  /// and the client would act on a header nobody signed.
  @Test("Relabelling the event name is rejected")
  func tamperedHeaderFails() async throws {
    let device = Curve25519.KeyAgreement.PrivateKey()
    let encoded = try await SealedPayloadCodec().encode(
      sampleEvent(name: .typingIndicator),
      projection: .full,
      capabilities: TargetCapabilities(
        supportedCodecs: [.sealedV2], publicKey: device.publicKey.rawRepresentation
      )
    )

    guard case .object(var fields) = encoded.body else {
      Issue.record("expected an object")
      return
    }
    fields["t"] = .string("new-message")

    #expect(throws: (any Error).self) {
      _ = try SealedPayloadCodec.open(envelope: .object(fields), using: device)
    }
  }

  /// A payload encrypted to one device must not be readable by another.
  @Test("Another device's key cannot open it")
  func wrongKeyFails() async throws {
    let intended = Curve25519.KeyAgreement.PrivateKey()
    let other = Curve25519.KeyAgreement.PrivateKey()

    let encoded = try await SealedPayloadCodec().encode(
      sampleEvent(),
      projection: .full,
      capabilities: TargetCapabilities(
        supportedCodecs: [.sealedV2], publicKey: intended.publicKey.rawRepresentation
      )
    )

    #expect(throws: (any Error).self) {
      _ = try SealedPayloadCodec.open(envelope: encoded.body, using: other)
    }
  }

  /// Failing closed. The negotiator falls back before reaching the codec, but a direct call
  /// must never quietly emit plaintext.
  @Test("Sealing without a key fails rather than sending plaintext")
  func missingKeyFails() async {
    await #expect(throws: SealedPayloadError.missingPublicKey) {
      _ = try await SealedPayloadCodec().encode(
        sampleEvent(),
        projection: .full,
        capabilities: TargetCapabilities(supportedCodecs: [.sealedV2], publicKey: nil)
      )
    }
  }

  @Test("A malformed public key is rejected at encode time")
  func invalidKeyFails() async {
    await #expect(throws: SealedPayloadError.invalidPublicKey) {
      _ = try await SealedPayloadCodec().encode(
        sampleEvent(),
        projection: .full,
        capabilities: TargetCapabilities(
          supportedCodecs: [.sealedV2], publicKey: Data(repeating: 0xAB, count: 31)
        )
      )
    }
  }

  /// The AAD is a dictionary on both sides, and Swift dictionary ordering is arbitrary and
  /// varies between processes. Without canonical encoding every tag check would fail
  /// intermittently — which is the worst possible way for this to break.
  @Test("The authenticated header encodes canonically")
  func authenticatedDataIsCanonical() throws {
    let header: [String: JSONValue] = [
      "v": .int(2), "t": .string("new-message"),
      "alg": .string("x25519-chacha20poly1305"), "ts": .int64(1),
    ]
    let first = try SealedPayloadCodec.authenticatedData(for: header)
    let second = try SealedPayloadCodec.authenticatedData(for: header)
    #expect(first == second)

    let text = String(decoding: first, as: UTF8.self)
    // Sorted, so both sides agree regardless of insertion order.
    #expect(text.hasPrefix("{\"alg\""))
  }

  /// A user who chose an encrypted codec has said they do not want content in the clear.
  @Test("Hints default to off and stay out of the plaintext header")
  func hintsDefaultOff() async throws {
    let device = Curve25519.KeyAgreement.PrivateKey()
    let encoded = try await SealedPayloadCodec().encode(
      sampleEvent(),
      projection: .full,
      capabilities: TargetCapabilities(
        supportedCodecs: [.sealedV2], publicKey: device.publicKey.rawRepresentation
      )
    )
    #expect(encoded.body["s"] == nil)
    #expect(encoded.body["p"] == nil)
  }

  /// When a hint IS enabled it must still be authenticated, or it could be swapped.
  @Test("An enabled hint is authenticated along with the rest of the header")
  func hintsAreAuthenticated() async throws {
    let device = Curve25519.KeyAgreement.PrivateKey()
    let encoded = try await SealedPayloadCodec(hint: .senderOnly).encode(
      sampleEvent(),
      projection: .full,
      capabilities: TargetCapabilities(
        supportedCodecs: [.sealedV2], publicKey: device.publicKey.rawRepresentation
      )
    )
    #expect(encoded.body["s"]?.stringValue == "+12025550143")

    guard case .object(var fields) = encoded.body else {
      Issue.record("expected an object")
      return
    }
    fields["s"] = .string("+12025550199")
    #expect(throws: (any Error).self) {
      _ = try SealedPayloadCodec.open(envelope: .object(fields), using: device)
    }
  }
}
