//  TokenVerifierTests
//  That a good token verifies and that every bad one fails, without anything untyped escaping.
//
//  The signing half is only ever exercised here and by the issuing service — the server never
//  creates a token — so these tests are also the executable specification of the wire format.

import BBCore
import Crypto
import Foundation
import Testing

@testable import BBLicense

@Suite("TokenVerifier")
struct TokenVerifierTests {

  static let key = Curve25519.Signing.PrivateKey()

  /// Mints a token the way the issuing service will.
  static func mint(
    claims: [String: Any],
    signedBy key: Curve25519.Signing.PrivateKey = key
  ) throws -> String {
    let header = try JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "typ": "JWT"])
    let payload = try JSONSerialization.data(withJSONObject: claims)
    let signing =
      "\(Base64URL.encode(header)).\(Base64URL.encode(payload))"
    let signature = try key.signature(for: Data(signing.utf8))
    return "\(signing).\(Base64URL.encode(signature))"
  }

  static func validClaims(overrides: [String: Any] = [:]) -> [String: Any] {
    var claims: [String: Any] = [
      "v": 1, "sub": "cus_1", "tier": "pro", "rank": 1, "feats": [],
      "machine": "abc123", "iat": 1_700_000_000, "exp": 1_700_600_000,
      "sub_end": 1_702_000_000, "jti": "tok_1",
    ]
    for (k, v) in overrides { claims[k] = v }
    return claims
  }

  @Test("A well-formed token verifies and decodes")
  func roundTrip() throws {
    let token = try Self.mint(claims: Self.validClaims())
    let decoded = try TokenVerifier.verify(token, publicKey: Self.key.publicKey)
    #expect(decoded.tier == .pro)
    #expect(decoded.subject == "cus_1")
    #expect(decoded.machine == "abc123")
    #expect(decoded.isPerpetual == false)
  }

  /// A missing `sub_end` is a missing DATE, not a statement about what was bought.
  ///
  /// It was read as "perpetual" until the real vendor produced the counter-example: Lemon
  /// Squeezy reports a license's `expires_at` as null while a subscription is ACTIVE, so every
  /// healthy monthly subscriber arrived without one and was told they owned the software.
  @Test("A missing sub_end decodes, and does not imply a purchase")
  func missingSubscriptionEnd() throws {
    var claims = Self.validClaims()
    claims.removeValue(forKey: "sub_end")
    let decoded = try TokenVerifier.verify(
      try Self.mint(claims: claims), publicKey: Self.key.publicKey)
    #expect(decoded.subscriptionEndsAt == nil)
    #expect(decoded.isPerpetual == false)
  }

  @Test("Perpetual is carried by its own claim")
  func perpetualClaim() throws {
    var claims = Self.validClaims(overrides: ["perp": true])
    claims.removeValue(forKey: "sub_end")
    let decoded = try TokenVerifier.verify(
      try Self.mint(claims: claims), publicKey: Self.key.publicKey)
    #expect(decoded.isPerpetual)
  }

  @Test("A token signed by another key fails")
  func wrongKey() throws {
    let token = try Self.mint(claims: Self.validClaims(), signedBy: Curve25519.Signing.PrivateKey())
    #expect(throws: TokenVerificationError.badSignature) {
      try TokenVerifier.verify(token, publicKey: Self.key.publicKey)
    }
  }

  @Test("A flipped byte in the claims fails")
  func tampered() throws {
    let token = try Self.mint(claims: Self.validClaims())
    var segments = token.split(separator: ".").map(String.init)
    // Re-encode altered claims against the ORIGINAL signature.
    let altered = try JSONSerialization.data(
      withJSONObject: Self.validClaims(overrides: ["tier": "crm", "rank": 99]))
    segments[1] = Base64URL.encode(altered)
    #expect(throws: TokenVerificationError.badSignature) {
      try TokenVerifier.verify(segments.joined(separator: "."), publicKey: Self.key.publicKey)
    }
  }

  @Test(
    "Malformed input throws a typed error rather than escaping",
    arguments: [
      "", "one.two", "a.b.c.d", "not-base64url!.@@@.###",
    ])
  func malformed(token: String) {
    #expect(throws: (any Error).self) {
      try TokenVerifier.verify(token, publicKey: Self.key.publicKey)
    }
  }

  /// Signed, and naming another algorithm: refused. The header used to go unread here,
  /// while the access-token verifier checked it; one rule now, in `CompactToken`.
  @Test("A token whose header does not name EdDSA is refused, however it is signed")
  func headerMustNameEdDSA() throws {
    let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
    let payload = try JSONSerialization.data(withJSONObject: Self.validClaims())
    let signing = "\(Base64URL.encode(header)).\(Base64URL.encode(payload))"
    let signature = try Self.key.signature(for: Data(signing.utf8))
    let token = "\(signing).\(Base64URL.encode(signature))"
    #expect(throws: TokenVerificationError.self) {
      try TokenVerifier.verify(token, publicKey: Self.key.publicKey)
    }
  }

  @Test("A newer claim format is refused rather than half-read")
  func futureVersion() throws {
    let token = try Self.mint(claims: Self.validClaims(overrides: ["v": 99]))
    #expect(throws: TokenVerificationError.unsupportedVersion(99)) {
      try TokenVerifier.verify(token, publicKey: Self.key.publicKey)
    }
  }

  /// An unconfigured build must refuse rather than accept, and it must say WHICH failure it
  /// is: `notConfigured` is "this build cannot evaluate a license", which is what
  /// `LicensePublicKey.isConfigured` turns into "gate nothing". Confusing it with a bad
  /// signature would mean an unconfigured build reporting every customer as a forger.
  ///
  /// Tested against an empty key rather than the shipped constant, so it keeps holding now
  /// that a real key IS compiled in.
  @Test("An empty public key is refused as unconfigured, not as a bad signature")
  func notConfigured() {
    #expect(throws: TokenVerificationError.notConfigured) {
      try LicensePublicKey.parse(base64: "")
    }
    #expect(throws: TokenVerificationError.notConfigured) {
      try LicensePublicKey.parse(base64: "   ")
    }
  }

  /// The shipped key, which is what every released server verifies against.
  ///
  /// Only its SHAPE is asserted: 32 raw bytes that Curve25519 accepts. Pinning the value
  /// would make rotating the keypair a test edit, and the value is not a secret anyway.
  @Test("The compiled-in public key is present and well-formed")
  func shippedKeyIsUsable() throws {
    #expect(LicensePublicKey.isConfigured, "the subscription gate is off without one")
    let key = try LicensePublicKey.parse(base64: LicensePublicKey.base64)
    #expect(key.rawRepresentation.count == 32)
  }
}

@Suite("SubscriptionTier")
struct SubscriptionTierTests {

  @Test("One tier ships")
  func shipped() {
    #expect(SubscriptionTier.shipped == [.pro])
  }

  @Test("A floor is satisfied by itself and by anything above it")
  func ordering() {
    let higher = SubscriptionTier(id: "higher", rank: 5, displayName: "Higher")
    #expect(SubscriptionTier.pro.satisfies(.pro))
    #expect(higher.satisfies(.pro))
    #expect(!SubscriptionTier.pro.satisfies(higher))
  }

  /// The forward-compatibility property: a tier introduced after this build shipped still
  /// works here, because the rank travels in the token.
  @Test("An unknown tier still orders, and outranks a known floor")
  func unknownTierStillOrders() {
    let future = SubscriptionTier.resolve(id: "crm", rank: 9)
    #expect(future.displayName == "crm")
    #expect(future.satisfies(.pro))
    #expect(future != SubscriptionTier.pro)
  }

  @Test("A known id keeps its display name but the token's rank")
  func knownIDKeepsIssuerRank() {
    let resolved = SubscriptionTier.resolve(id: "pro", rank: 42)
    #expect(resolved.displayName == "Pro")
    #expect(resolved.rank == 42)
    #expect(resolved == SubscriptionTier.pro)
  }
}
