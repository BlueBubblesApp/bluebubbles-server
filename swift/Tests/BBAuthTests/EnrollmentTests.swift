//  EnrollmentTests
//  Enrollment, tokens, rotation and revocation — the machinery once it is switched on.
//
//  NO REAL CREDENTIALS — every secret here is generated per-run.

import BBSettings
import Crypto
import Foundation
import Testing

@testable import BBAuth

private final class MemorySecrets: SecretStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: String] = [:]
  func get(_ key: String) throws -> String? { lock.withLock { storage[key] } }
  func set(_ key: String, value: String) throws { lock.withLock { storage[key] = value } }
  func delete(_ key: String) throws { _ = lock.withLock { storage.removeValue(forKey: key) } }
}

private func enabledService() -> TokenAuthService {
  TokenAuthService(
    configuration: TokenAuthConfiguration(mode: .token),
    secrets: MemorySecrets()
  )
}

@Suite("Enrollment codes")
struct EnrollmentCodeTests {

  /// Crockford base32: a code read off a screen and typed into a phone must not become a
  /// different VALID code through a misread character.
  @Test("The alphabet excludes the characters people misread")
  func alphabetIsUnambiguous() {
    #expect(EnrollmentCode.alphabet.count == 32, "a non-power-of-two alphabet biases the modulo")
    for character in ["I", "L", "O", "U"] {
      #expect(!EnrollmentCode.alphabet.contains(Character(character)))
    }
  }

  /// Crockford's decoding rules exist because people transcribe these by hand.
  @Test("Normalisation applies Crockford's decoding rules")
  func normalisation() {
    // I and L read as 1, O reads as 0, case and hyphens are irrelevant.
    #expect(EnrollmentCode.normalize("il0o") == "1100")
    #expect(EnrollmentCode.normalize("abcd-efgh") == "ABCDEFGH")
    #expect(EnrollmentCode.normalize("ab cd") == "ABCD")
  }

  @Test("A code matches its own normalised forms")
  func matching() {
    let code = EnrollmentCode(value: "ABCD1234", expiresAt: .distantFuture)
    #expect(code.matches("abcd1234"))
    #expect(code.matches("ABCD-1234"))
    #expect(!code.matches("ABCD1235"))
  }

  @Test("A code expires")
  func expiry() {
    let now = Date()
    let code = EnrollmentCode.generate(now: now)
    #expect(code.isValid(at: now))
    #expect(code.isValid(at: now.addingTimeInterval(299)))
    #expect(!code.isValid(at: now.addingTimeInterval(301)))
  }

  @Test("Codes are the declared length and do not repeat")
  func generation() {
    let codes = Set((0..<500).map { _ in EnrollmentCode.generate().value })
    #expect(codes.count == 500)
    for code in codes {
      #expect(code.count == EnrollmentCode.length)
      #expect(code.allSatisfy { EnrollmentCode.alphabet.contains($0) })
    }
  }

  /// Single use. A code that could be retried is a code that can be brute-forced — and 40
  /// bits is guessable if you get unlimited attempts.
  @Test("A code works once and then never again")
  func singleUse() async throws {
    let registry = DeviceRegistry()
    let code = await registry.issueEnrollmentCode()

    try await registry.consumeEnrollmentCode(code.value)
    await #expect(throws: EnrollmentError.invalidEnrollmentCode) {
      try await registry.consumeEnrollmentCode(code.value)
    }
  }

  /// Consumed even when it has expired, so an expired code cannot be retried either.
  @Test("An expired code is rejected and consumed")
  func expiredCodeRejected() async throws {
    let registry = DeviceRegistry()
    let start = Date()
    let code = await registry.issueEnrollmentCode(now: start)

    await #expect(throws: EnrollmentError.enrollmentCodeExpired) {
      try await registry.consumeEnrollmentCode(
        code.value, now: start.addingTimeInterval(400)
      )
    }
  }

  @Test("An unknown code is rejected")
  func unknownCodeRejected() async {
    let registry = DeviceRegistry()
    await #expect(throws: EnrollmentError.invalidEnrollmentCode) {
      try await registry.consumeEnrollmentCode("ZZZZZZZZ")
    }
  }
}

@Suite("Secret hashing")
struct SecretHashTests {

  @Test("A secret verifies against its own hash and nothing else")
  func verification() throws {
    let secret = ClientSecret.generate()
    let hash = try SecretHash.make(secret)

    #expect(hash.verify(secret))
    #expect(!hash.verify(ClientSecret.generate()))
    #expect(!hash.verify(""))
  }

  /// A fresh salt per secret, so two devices that somehow shared a secret would still not
  /// share a hash.
  @Test("Each hash uses a fresh salt")
  func saltsAreUnique() throws {
    let secret = "the-same-secret"
    let first = try SecretHash.make(secret)
    let second = try SecretHash.make(secret)

    #expect(first.salt != second.salt)
    #expect(first.hash != second.hash)
    // Both still verify, which is the point of the salt being stored alongside.
    #expect(first.verify(secret))
    #expect(second.verify(secret))
  }

  /// The precondition that makes the hashing choice sound: secrets are server-generated at
  /// full length, never supplied by a caller. A user-chosen secret would invalidate the
  /// entropy argument entirely — see the note on SecretHash.
  @Test("Generated secrets carry full entropy and never repeat")
  func secretsAreHighEntropy() {
    let secrets = Set((0..<500).map { _ in ClientSecret.generate() })
    #expect(secrets.count == 500)
    // 32 bytes base64url-encoded, unpadded.
    for secret in secrets {
      #expect(secret.count >= 42)
      #expect(!secret.contains("="))
      #expect(!secret.contains("+"))
      #expect(!secret.contains("/"))
    }
  }
}

@Suite("Device lifecycle")
struct DeviceLifecycleTests {

  @Test("Enrolling mints credentials that authenticate")
  func enrollAndAuthenticate() async throws {
    let registry = DeviceRegistry()
    let (credentials, device) = try await registry.enroll(
      name: "Pixel", platform: "android"
    )

    #expect(credentials.clientId.hasPrefix("bb_"))
    #expect(device.scopes == Scope.all, "enrollment grants everything so nothing breaks")

    let authenticated = try await registry.authenticate(
      clientId: credentials.clientId, clientSecret: credentials.clientSecret
    )
    #expect(authenticated.id == device.id)
    #expect(authenticated.lastSeenAt != nil)
  }

  /// The secret is returned once and stored hashed — the server itself cannot recover it.
  @Test("The stored device holds a hash, never the secret")
  func secretIsNotStored() async throws {
    let registry = DeviceRegistry()
    let (credentials, _) = try await registry.enroll(name: "Pixel", platform: "android")

    let stored = try #require(await registry.device(clientId: credentials.clientId))
    let encoded = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
    #expect(!encoded.contains(credentials.clientSecret))
  }

  @Test("A wrong secret is rejected")
  func wrongSecretRejected() async throws {
    let registry = DeviceRegistry()
    let (credentials, _) = try await registry.enroll(name: "Pixel", platform: "android")

    await #expect(throws: EnrollmentError.invalidClientCredentials) {
      _ = try await registry.authenticate(
        clientId: credentials.clientId, clientSecret: ClientSecret.generate()
      )
    }
  }

  /// An unknown client id must not be distinguishable from a wrong secret — otherwise the
  /// error enumerates which client ids exist.
  @Test("An unknown client id fails the same way as a wrong secret")
  func unknownClientIndistinguishable() async {
    let registry = DeviceRegistry()
    await #expect(throws: EnrollmentError.invalidClientCredentials) {
      _ = try await registry.authenticate(clientId: "bb_nope", clientSecret: "x")
    }
  }

  /// The point of the whole phase: revocation is one row, not a password change for every
  /// device the user owns.
  @Test("Revoking one device leaves the others working")
  func revocationIsPerDevice() async throws {
    let registry = DeviceRegistry()
    let (first, firstDevice) = try await registry.enroll(name: "Phone", platform: "android")
    let (second, _) = try await registry.enroll(name: "Tablet", platform: "android")

    try await registry.revoke(id: firstDevice.id)

    await #expect(throws: EnrollmentError.deviceRevoked) {
      _ = try await registry.authenticate(
        clientId: first.clientId, clientSecret: first.clientSecret
      )
    }
    // The other device is untouched.
    _ = try await registry.authenticate(
      clientId: second.clientId, clientSecret: second.clientSecret
    )
  }

  /// Marked rather than deleted, so a user who revokes the wrong phone can see what they
  /// did rather than watching it vanish.
  @Test("A revoked device stays visible")
  func revokedDeviceRemainsListed() async throws {
    let registry = DeviceRegistry()
    let (_, device) = try await registry.enroll(name: "Phone", platform: "android")
    try await registry.revoke(id: device.id)

    let listed = try await registry.allDevices()
    #expect(listed.count == 1)
    #expect(listed.first?.isRevoked == true)
  }

  /// Rotation exists so a suspected leak does not mean re-enrolling — which on a phone
  /// means finding the server UI again.
  @Test("Rotation issues a new secret and kills the old one")
  func rotation() async throws {
    let registry = DeviceRegistry()
    let (original, _) = try await registry.enroll(name: "Phone", platform: "android")

    let rotated = try await registry.rotateSecret(
      clientId: original.clientId, currentSecret: original.clientSecret
    )
    #expect(rotated.clientId == original.clientId)
    #expect(rotated.clientSecret != original.clientSecret)

    _ = try await registry.authenticate(
      clientId: rotated.clientId, clientSecret: rotated.clientSecret
    )
    await #expect(throws: EnrollmentError.invalidClientCredentials) {
      _ = try await registry.authenticate(
        clientId: original.clientId, clientSecret: original.clientSecret
      )
    }
  }

  @Test("Rotation requires the current secret")
  func rotationRequiresCurrentSecret() async throws {
    let registry = DeviceRegistry()
    let (original, _) = try await registry.enroll(name: "Phone", platform: "android")

    await #expect(throws: EnrollmentError.invalidClientCredentials) {
      _ = try await registry.rotateSecret(
        clientId: original.clientId, currentSecret: ClientSecret.generate()
      )
    }
  }

  /// §4 composes with §5: the key submitted at enrollment is the one sealed-v2 encrypts to,
  /// so one handshake covers identity, codecs and encryption.
  @Test("Enrollment carries codec capability and a public key")
  func enrollmentCarriesCodecCapability() async throws {
    let registry = DeviceRegistry()
    let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation

    let (credentials, _) = try await registry.enroll(
      name: "Phone", platform: "android",
      publicKey: key, supportedCodecs: ["sealed-v2", "reference-v2"]
    )

    let stored = try #require(await registry.device(clientId: credentials.clientId))
    #expect(stored.publicKey == key)
    #expect(stored.supportedCodecs.contains("sealed-v2"))
  }
}
