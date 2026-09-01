//  NegotiationTests
//  Per-target codec selection, and the default that must not drift.
//
//  The load-bearing assertion in this file is the default-off one: a server that has not
//  enabled an alternate codec must emit legacy-v1 to every target no matter what any client
//  advertises. "Available but unused" quietly becoming "used" is exactly the kind of drift
//  the compatibility contract exists to prevent, and it would not show up as a failure —
//  clients would simply start getting payloads they cannot read.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBSerialization
import Crypto
import Foundation
import Testing

@testable import BBEvents

private func event(_ name: EventName = .newMessage) -> ServerEvent {
  ServerEvent(
    name: name,
    fullPayload: .object([
      "guid": .string("A1B2C3D4-0000-0000-0000-000000000001"),
      "text": .string("Hello"),
      "isFromMe": .bool(false),
      "handle": .object(["address": .string("+12025550143")]),
      "chats": .array([.object(["guid": .string("iMessage;-;+12025550143")])]),
    ]),
    occurredAt: Date(timeIntervalSince1970: 1_740_000_000)
  )
}

@Suite("Codec negotiation")
struct NegotiationTests {

  /// THE default-off test. A client cannot opt itself into a codec the server has not
  /// enabled — the ceiling is applied before the target's preferences are consulted.
  @Test("A default server emits legacy-v1 however capable the client claims to be")
  func defaultServerIgnoresClientCapability() async throws {
    let negotiator = CodecNegotiator.full(preference: .legacyV1)
    let device = Curve25519.KeyAgreement.PrivateKey()

    let capable = TargetCapabilities(
      supportedCodecs: [.legacyV1, .referenceV2, .sealedV2],
      publicKey: device.publicKey.rawRepresentation
    )
    #expect(negotiator.resolve(for: capable).identifier == .legacyV1)

    // And the payload really is the untouched object, not a re-encoded one.
    let encoded = try await negotiator.resolve(for: capable).encode(
      event(), projection: .full, capabilities: capable
    )
    #expect(encoded.body["text"]?.stringValue == "Hello")
  }

  @Test("A legacy client gets legacy-v1 even from a fully-enabled server")
  func legacyClientAlwaysGetsLegacy() {
    let negotiator = CodecNegotiator.full(preference: .sealedV2)
    #expect(negotiator.resolve(for: .legacy).identifier == .legacyV1)
  }

  /// `min(serverPreference, targetSupport)` — the ceiling caps, the target chooses beneath.
  @Test("The best codec both sides allow is chosen")
  func picksBestMutuallySupported() {
    let device = Curve25519.KeyAgreement.PrivateKey()
    let negotiator = CodecNegotiator.full(preference: .sealedV2)

    let sealedCapable = TargetCapabilities(
      supportedCodecs: [.legacyV1, .referenceV2, .sealedV2],
      publicKey: device.publicKey.rawRepresentation
    )
    #expect(negotiator.resolve(for: sealedCapable).identifier == .sealedV2)

    let referenceOnly = TargetCapabilities(supportedCodecs: [.legacyV1, .referenceV2])
    #expect(negotiator.resolve(for: referenceOnly).identifier == .referenceV2)
  }

  /// A ceiling below what the client supports still caps it.
  @Test("The server ceiling caps a more capable client")
  func ceilingCaps() {
    let device = Curve25519.KeyAgreement.PrivateKey()
    let negotiator = CodecNegotiator.full(preference: .referenceV2)
    let capable = TargetCapabilities(
      supportedCodecs: [.legacyV1, .referenceV2, .sealedV2],
      publicKey: device.publicKey.rawRepresentation
    )
    #expect(negotiator.resolve(for: capable).identifier == .referenceV2)
  }

  /// sealed-v2 without a key is not sealed-v2. Falling back is documented behaviour;
  /// failing the delivery would be worse, and sending plaintext under a sealed label would
  /// be far worse.
  @Test("A device claiming sealed-v2 without a key falls back to reference-v2")
  func sealedWithoutKeyFallsBack() {
    let negotiator = CodecNegotiator.full(preference: .sealedV2)
    let claiming = TargetCapabilities(
      supportedCodecs: [.legacyV1, .referenceV2, .sealedV2], publicKey: nil
    )
    #expect(negotiator.resolve(for: claiming).identifier == .referenceV2)
  }

  @Test("Without reference-v2 either, it falls all the way back to legacy")
  func sealedWithoutKeyOrReferenceFallsToLegacy() {
    let negotiator = CodecNegotiator.full(preference: .sealedV2)
    let claiming = TargetCapabilities(supportedCodecs: [.legacyV1, .sealedV2], publicKey: nil)
    #expect(negotiator.resolve(for: claiming).identifier == .legacyV1)
  }

  /// The property that makes this deployable against a fleet that will never fully upgrade:
  /// one event, three targets, three different payloads, one fan-out.
  @Test("One event produces different payloads for different targets")
  func mixedFleet() async throws {
    let device = Curve25519.KeyAgreement.PrivateKey()
    let negotiator = CodecNegotiator.full(preference: .sealedV2)
    let source = event()

    let sealedTarget = TargetCapabilities(
      supportedCodecs: [.legacyV1, .sealedV2],
      publicKey: device.publicKey.rawRepresentation
    )
    let referenceTarget = TargetCapabilities(supportedCodecs: [.legacyV1, .referenceV2])

    let sealed = try await negotiator.resolve(for: sealedTarget)
      .encode(source, projection: .notification, capabilities: sealedTarget)
    let reference = try await negotiator.resolve(for: referenceTarget)
      .encode(source, projection: .notification, capabilities: referenceTarget)
    let legacy = try await negotiator.resolve(for: .legacy)
      .encode(source, projection: .notification, capabilities: .legacy)

    #expect(sealed.codec == .sealedV2)
    #expect(reference.codec == .referenceV2)
    #expect(legacy.codec == .legacyV1)

    // The sealed one is genuinely opaque, the legacy one genuinely is not.
    #expect(sealed.body["ct"]?.stringValue != nil)
    #expect(reference.body["g"]?.stringValue == "A1B2C3D4-0000-0000-0000-000000000001")
    #expect(legacy.body["text"]?.stringValue == "Hello")
  }
}

@Suite("Capability declaration")
struct CapabilityDeclarationTests {

  /// Every existing client sends nothing, and must keep working.
  @Test("An absent declaration means legacy")
  func absentMeansLegacy() {
    #expect(TargetCapabilities.fromSocketHandshake(codecs: nil).supportedCodecs == [.legacyV1])
    #expect(TargetCapabilities.fromSocketHandshake(codecs: "").supportedCodecs == [.legacyV1])
  }

  @Test("A comma-separated list parses, with legacy always included")
  func parsesList() {
    let capabilities = TargetCapabilities.fromSocketHandshake(
      codecs: "sealed-v2, reference-v2"
    )
    #expect(capabilities.supportedCodecs.contains(.sealedV2))
    #expect(capabilities.supportedCodecs.contains(.referenceV2))
    // Unioned in unconditionally: every client can read it by definition, so negotiation
    // always has a floor.
    #expect(capabilities.supportedCodecs.contains(.legacyV1))
  }

  /// A client advertising a codec we have never heard of must not break its handshake —
  /// that would break clients we have not shipped yet.
  @Test("An unrecognised codec name degrades rather than failing")
  func unknownCodecDegrades() {
    let capabilities = TargetCapabilities.fromSocketHandshake(codecs: "quantum-v9")
    #expect(capabilities.supportedCodecs.contains(.legacyV1))
    #expect(
      CodecNegotiator.full(preference: .sealedV2)
        .resolve(for: capabilities).identifier == .legacyV1)
  }

  /// X25519 keys are exactly 32 bytes. Accepting anything else defers the failure to a
  /// send, where it looks like a delivery problem rather than a registration one.
  @Test("A public key is accepted only at the right length")
  func publicKeyLengthIsChecked() {
    let valid = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    #expect(TargetCapabilities.decodePublicKey(valid.base64EncodedString()) == valid)

    #expect(
      TargetCapabilities.decodePublicKey(
        Data(repeating: 0, count: 31).base64EncodedString()
      ) == nil)
    #expect(TargetCapabilities.decodePublicKey("not base64 at all!!") == nil)
    #expect(TargetCapabilities.decodePublicKey(nil) == nil)
    #expect(TargetCapabilities.decodePublicKey("") == nil)
  }

  /// Registration bodies carry the list as a JSON array rather than a string.
  @Test("Registration fields parse from an array or a string")
  func registrationParsing() {
    let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation

    let arrayForm = TargetCapabilities.fromRegistration(
      .object([
        "supportedCodecs": .array([.string("sealed-v2"), .string("reference-v2")]),
        "publicKey": .string(key.base64EncodedString()),
      ]))
    #expect(arrayForm.supportedCodecs.contains(.sealedV2))
    #expect(arrayForm.publicKey == key)

    let stringForm = TargetCapabilities.fromRegistration(
      .object([
        "supportedCodecs": .string("reference-v2")
      ]))
    #expect(stringForm.supportedCodecs.contains(.referenceV2))

    // A registration that declares nothing is every device registered before this shipped.
    let bare = TargetCapabilities.fromRegistration(.object([:]))
    #expect(bare.supportedCodecs == [.legacyV1])
    #expect(bare.publicKey == nil)
  }
}

@Suite("Codec advertisement")
struct AdvertisementTests {

  /// The parity harness diffs `server/info` strictly in both directions, so an added key
  /// fails it. A default server has nothing new to offer and must say nothing new.
  @Test("A legacy-only server advertises no new fields")
  func legacyOnlyAdvertisesNothing() {
    #expect(CodecNegotiator.legacyOnly().advertisement.fields().isEmpty)
  }

  /// The case a unit test missed and a curl found. The composition root registers all
  /// three codecs so the ceiling can be raised without a rebuild — so a DEFAULT server has
  /// three registered and one reachable, and must still advertise nothing. Gating on the
  /// registration count instead of the preference made a stock server announce `sealed-v2`
  /// it would never use, which the parity harness would fail on an added key.
  @Test("A server with codecs registered but not enabled advertises nothing")
  func registeredButNotEnabledAdvertisesNothing() {
    let negotiator = CodecNegotiator.full(preference: .legacyV1)
    #expect(negotiator.supportedIdentifiers.count == 3)
    #expect(negotiator.advertisement.fields().isEmpty)
  }

  @Test("A server with alternates enabled advertises them")
  func enabledServerAdvertises() {
    let fields = CodecNegotiator.full(preference: .referenceV2).advertisement.fields()
    #expect(fields["payload_codec"]?.stringValue == "reference-v2")

    let supported =
      fields["supported_payload_codecs"]?.arrayValue?
      .compactMap(\.stringValue) ?? []
    #expect(supported.contains("sealed-v2"))
    #expect(supported.contains("legacy-v1"))
  }

  /// Registering the codecs without raising the ceiling is the "built to be switchable, not
  /// switched" default — the capability is discoverable, but nothing is using it.
  @Test("Codecs can be registered without being used")
  func registeredButNotUsed() {
    let negotiator = CodecNegotiator.full(preference: .legacyV1)
    #expect(negotiator.supportedIdentifiers.count == 3)
    #expect(
      negotiator.resolve(
        for: TargetCapabilities(
          supportedCodecs: [.legacyV1, .referenceV2]
        )
      ).identifier == .legacyV1)
  }
}
