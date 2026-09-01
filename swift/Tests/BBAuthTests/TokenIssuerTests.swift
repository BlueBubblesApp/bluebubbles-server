//  TokenIssuerTests
//  Access tokens: claims, signing, expiry, and revocation taking effect.
//
//  Signed with swift-crypto and verified with CryptoKit's Ed25519 through a separately
//  constructed public key — a token verified only by the code that minted it proves nothing,
//  since the same mistake on both sides cancels out.
//
//  NO REAL CREDENTIALS — see CONTRIBUTING.md.

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

/// A provider over a key the test also holds, so signatures can be checked independently.
private struct FixedKeyProvider: SigningKeyProviding {
  let key: Curve25519.Signing.PrivateKey
  func signingKey() async throws -> Curve25519.Signing.PrivateKey { key }
}

private func device(scopes: Set<Scope> = Scope.all) throws -> EnrolledDevice {
  EnrolledDevice(
    id: DeviceID("device-1"),
    clientId: "bb_testclient",
    secret: try SecretHash.make(ClientSecret.generate()),
    name: "Test Phone",
    platform: "android",
    scopes: scopes
  )
}

private func decodeBase64URL(_ text: String) -> Data? {
  var padded =
    text
    .replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  while padded.count % 4 != 0 { padded += "=" }
  return Data(base64Encoded: padded)
}

@Suite("Access tokens")
struct TokenIssuerTests {

  @Test("A token carries the documented claims")
  func claims() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let issuer = TokenIssuer(keyProvider: FixedKeyProvider(key: key))
    let now = Date(timeIntervalSince1970: 1_740_000_000)

    let grant = try await issuer.issue(for: try device(), now: now)
    #expect(grant.tokenType == "Bearer")
    #expect(grant.expiresIn == 3600)

    let parts = grant.accessToken.split(separator: ".")
    #expect(parts.count == 3)

    let claimData = try #require(decodeBase64URL(String(parts[1])))
    let claims = try JSONDecoder().decode(TokenClaims.self, from: claimData)

    #expect(claims.sub == "bb_testclient")
    #expect(claims.iss == "bluebubbles-server")
    #expect(claims.iat == 1_740_000_000)
    #expect(claims.exp == 1_740_000_000 + 3600)
    #expect(!claims.jti.isEmpty)
  }

  @Test("The header declares EdDSA")
  func header() async throws {
    let issuer = TokenIssuer(
      keyProvider: FixedKeyProvider(key: Curve25519.Signing.PrivateKey())
    )
    let grant = try await issuer.issue(for: try device())

    let headerData = try #require(
      decodeBase64URL(String(grant.accessToken.split(separator: ".")[0]))
    )
    let header = try #require(
      try JSONSerialization.jsonObject(with: headerData) as? [String: Any]
    )
    #expect(header["alg"] as? String == "EdDSA")
    #expect(header["typ"] as? String == "JWT")
  }

  /// Verified against a public key the test constructs itself, not through the issuer.
  @Test("The signature verifies under an independently held key")
  func signatureVerifies() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let issuer = TokenIssuer(keyProvider: FixedKeyProvider(key: key))
    let grant = try await issuer.issue(for: try device())

    let parts = grant.accessToken.split(separator: ".")
    let signingInput = "\(parts[0]).\(parts[1])"
    let signature = try #require(decodeBase64URL(String(parts[2])))

    let publicKey = try Curve25519.Signing.PublicKey(
      rawRepresentation: key.publicKey.rawRepresentation
    )
    #expect(publicKey.isValidSignature(signature, for: Data(signingInput.utf8)))
  }

  /// Otherwise the previous test proves only that bytes were produced.
  @Test("A tampered claim set fails verification")
  func tamperedClaimsRejected() async throws {
    let issuer = TokenIssuer(
      keyProvider: FixedKeyProvider(key: Curve25519.Signing.PrivateKey())
    )
    let grant = try await issuer.issue(for: try device())
    let parts = grant.accessToken.split(separator: ".")

    // Same signature, escalated scope.
    let forged = TokenIssuer.base64URL(
      Data(
        #"{"sub":"bb_testclient","scope":"server:admin","jti":"x","iat":1,"exp":9999999999,"iss":"bluebubbles-server"}"#
          .utf8)
    )
    await #expect(throws: TokenError.badSignature) {
      _ = try await issuer.verify("\(parts[0]).\(forged).\(parts[2])")
    }
  }

  @Test("A token from another server's key is rejected")
  func foreignKeyRejected() async throws {
    let ours = TokenIssuer(keyProvider: FixedKeyProvider(key: Curve25519.Signing.PrivateKey()))
    let theirs = TokenIssuer(keyProvider: FixedKeyProvider(key: Curve25519.Signing.PrivateKey()))

    let grant = try await theirs.issue(for: try device())
    await #expect(throws: TokenError.badSignature) {
      _ = try await ours.verify(grant.accessToken)
    }
  }

  @Test("An expired token is rejected")
  func expiredRejected() async throws {
    let issuer = TokenIssuer(
      keyProvider: FixedKeyProvider(key: Curve25519.Signing.PrivateKey())
    )
    let issuedAt = Date(timeIntervalSince1970: 1_740_000_000)
    let grant = try await issuer.issue(for: try device(), now: issuedAt)

    await #expect(throws: TokenError.expired) {
      _ = try await issuer.verify(
        grant.accessToken, now: issuedAt.addingTimeInterval(3600 + 120)
      )
    }
    // Still valid just before, allowing for the skew tolerance.
    _ = try await issuer.verify(
      grant.accessToken, now: issuedAt.addingTimeInterval(3500)
    )
  }

  @Test("A malformed token is rejected without crashing")
  func malformedRejected() async throws {
    let issuer = TokenIssuer(
      keyProvider: FixedKeyProvider(key: Curve25519.Signing.PrivateKey())
    )
    for candidate in ["", "not-a-token", "a.b", "a.b.c.d", "...."] {
      await #expect(throws: (any Error).self) { _ = try await issuer.verify(candidate) }
    }
  }

  /// Scope travels as a space-separated string, matching OAuth 2.0 rather than inventing a
  /// list encoding.
  @Test("Scopes round-trip through the claim")
  func scopeEncoding() async throws {
    let issuer = TokenIssuer(
      keyProvider: FixedKeyProvider(key: Curve25519.Signing.PrivateKey())
    )
    let grant = try await issuer.issue(
      for: try device(scopes: [.messagesRead, .attachmentsRead])
    )
    let claims = try await issuer.verify(grant.accessToken)

    #expect(claims.scopes == [.messagesRead, .attachmentsRead])
    #expect(claims.scope == "attachments:read messages:read", "sorted, so it is deterministic")
  }
}

@Suite("Signing key lifecycle")
struct SigningKeyTests {

  /// Created lazily, because under the default configuration it must never be created at
  /// all — a key the user did not ask for is a secret they now have to protect.
  @Test("The key is created on first use and then reused")
  func lazyCreation() async throws {
    let secrets = MemorySecrets()
    let provider = KeychainSigningKeyProvider(secrets: secrets)

    #expect(await !provider.hasKey())
    let first = try await provider.signingKey()
    #expect(await provider.hasKey())

    let second = try await provider.signingKey()
    #expect(first.rawRepresentation == second.rawRepresentation)
  }

  /// Tokens must survive a restart, which means the key must come back from the Keychain
  /// rather than being regenerated.
  @Test("A token survives a new provider over the same store")
  func keyPersists() async throws {
    let secrets = MemorySecrets()
    let issuer = TokenIssuer(keyProvider: KeychainSigningKeyProvider(secrets: secrets))
    let grant = try await issuer.issue(for: try device())

    let afterRestart = TokenIssuer(keyProvider: KeychainSigningKeyProvider(secrets: secrets))
    let claims = try await afterRestart.verify(grant.accessToken)
    #expect(claims.sub == "bb_testclient")
  }
}

@Suite("Bearer scheme")
struct BearerSchemeTests {

  private func makeScheme() async throws
    -> (BearerTokenScheme, DeviceRegistry, TokenIssuer, ClientCredentials, EnrolledDevice)
  {
    let registry = DeviceRegistry()
    let issuer = TokenIssuer(
      keyProvider: KeychainSigningKeyProvider(secrets: MemorySecrets())
    )
    let (credentials, device) = try await registry.enroll(
      name: "Phone", platform: "android"
    )
    return (
      BearerTokenScheme(issuer: issuer, registry: registry),
      registry, issuer, credentials, device
    )
  }

  @Test("A valid token authenticates and carries the device identity")
  func validTokenAuthenticates() async throws {
    let (scheme, registry, issuer, credentials, device) = try await makeScheme()
    let stored = try #require(await registry.device(clientId: credentials.clientId))
    let grant = try await issuer.issue(for: stored)

    let principal = try await scheme.authenticate(
      CredentialPresentation(authorizationHeader: "Bearer \(grant.accessToken)")
    )
    // The thing the shared password cannot provide.
    #expect(principal?.deviceID == device.id)
    #expect(principal?.schemeID == "bearer-token")
  }

  /// Without the device lookup, a revoked device would keep working until its token
  /// expired — up to an hour of access after the user pressed Revoke.
  @Test("Revocation takes effect immediately, not at token expiry")
  func revocationIsImmediate() async throws {
    let (scheme, registry, issuer, credentials, device) = try await makeScheme()
    let stored = try #require(await registry.device(clientId: credentials.clientId))
    let grant = try await issuer.issue(for: stored)

    // Works before.
    _ = try await scheme.authenticate(
      CredentialPresentation(authorizationHeader: "Bearer \(grant.accessToken)")
    )

    try await registry.revoke(id: device.id)

    // The token is still cryptographically valid; the device is not.
    await #expect(throws: AuthenticationFailure.revoked) {
      _ = try await scheme.authenticate(
        CredentialPresentation(authorizationHeader: "Bearer \(grant.accessToken)")
      )
    }
  }

  /// Scopes come from the DEVICE, not the token — so narrowing a device's scopes takes
  /// effect at once rather than when its outstanding tokens expire.
  @Test("Scopes are read from the device, not from the token")
  func scopesComeFromTheDevice() async throws {
    let (scheme, registry, issuer, credentials, _) = try await makeScheme()
    var stored = try #require(await registry.device(clientId: credentials.clientId))
    let grant = try await issuer.issue(for: stored)

    stored.scopes = [.messagesRead]
    try await registry.update(stored)

    let principal = try await scheme.authenticate(
      CredentialPresentation(authorizationHeader: "Bearer \(grant.accessToken)")
    )
    #expect(principal?.scopes == [.messagesRead])
  }

  /// No credential of this kind means fall through, not fail — that is what lets `both`
  /// accept a query-param password.
  @Test("A request without a bearer token falls through")
  func noTokenFallsThrough() async throws {
    let (scheme, _, _, _, _) = try await makeScheme()
    #expect(try await scheme.authenticate(CredentialPresentation()) == nil)
    // A `Bearer <password>` header is not a JWT and must not be consumed here.
    #expect(
      try await scheme.authenticate(
        CredentialPresentation(authorizationHeader: "Bearer correct-horse")
      ) == nil)
  }

  /// Socket.IO v4 carries credentials in its native `auth: {token}` field, which arrives as
  /// a query parameter — the same chain has to serve both transports.
  @Test("A Socket.IO handshake token is accepted")
  func socketHandshakeToken() async throws {
    let (scheme, registry, issuer, credentials, device) = try await makeScheme()
    let stored = try #require(await registry.device(clientId: credentials.clientId))
    let grant = try await issuer.issue(for: stored)

    let principal = try await scheme.authenticate(
      CredentialPresentation(queryParameters: ["auth_token": grant.accessToken])
    )
    #expect(principal?.deviceID == device.id)
  }
}
