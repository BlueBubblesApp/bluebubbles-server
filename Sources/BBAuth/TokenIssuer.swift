//  TokenIssuer
//  Short-lived Ed25519 access tokens.
//
//  Why no refresh token
//  --------------------
//  Because the client already holds a durable, device-specific secret from enrollment, it can
//  re-mint an access token whenever it likes. A refresh token would be a second long-lived
//  credential doing the job the first one already does; that is a simplification over a
//  user-facing OAuth flow rather than a compromise. Access tokens live an hour and are cheap
//  to replace; revoking a device is deleting one row.
//
//  Why Ed25519 rather than HMAC
//  ----------------------------
//  Verification is stateless (no database read on the hot path) and the verifying key is
//  public. That matters for what comes later: a proxy or a companion process could verify a
//  token without being trusted to MINT one, which a shared HMAC secret cannot express.
//
//  All of it is dormant by default: with `auth_mode = password` no signing key is ever
//  generated. See `docs/AUTH.md`.

import BBCore
import BBSettings
import Crypto
import Foundation

public enum TokenError: BBError, Equatable {
  case malformed
  case badSignature
  case expired
  case notYetValid
  case wrongIssuer
  /// A key is stored and does not decode. Never replaced on the spot: a new key invalidates
  /// every token every enrolled device holds.
  case unreadableSigningKey
}

/// A minted token and when it dies.
public struct AccessTokenGrant: Sendable, Equatable {
  public let accessToken: String
  public let expiresIn: Int
  public let tokenType: String
  public let scope: String

  public init(accessToken: String, expiresIn: Int, scope: String, tokenType: String = "Bearer") {
    self.accessToken = accessToken
    self.expiresIn = expiresIn
    self.scope = scope
    self.tokenType = tokenType
  }
}

/// The claims carried in an access token.
public struct TokenClaims: Sendable, Equatable, Codable {
  /// The client id the token was minted for.
  public let sub: String
  /// Space-separated, matching OAuth 2.0 rather than inventing a list encoding.
  public let scope: String
  /// A unique id per token. Not used for revocation (that is what the device row is for)
  /// but it makes a token traceable in logs without logging the token itself.
  public let jti: String
  public let iat: Int
  public let exp: Int
  public let iss: String

  public var scopes: Set<Scope> {
    Set(scope.split(separator: " ").compactMap { Scope(rawValue: String($0)) })
  }
}

public actor TokenIssuer {

  /// One hour. Short because re-minting is cheap, and because a stolen token is only useful
  /// until it expires: revoking the device stops new ones being issued, but cannot recall
  /// one already in flight.
  public static let lifetime: TimeInterval = 3600
  public static let issuer = "bluebubbles-server"

  private let keyProvider: any SigningKeyProviding
  /// What "now" is when a token is minted and when one is checked. Injected so a test can
  /// mint a token and verify it an hour later without waiting an hour.
  private let clock: any BBClock
  private var cachedKey: Curve25519.Signing.PrivateKey?

  public init(keyProvider: any SigningKeyProviding, clock: any BBClock = SystemClock()) {
    self.keyProvider = keyProvider
    self.clock = clock
  }

  private func signingKey() async throws -> Curve25519.Signing.PrivateKey {
    if let cachedKey { return cachedKey }
    let key = try await keyProvider.signingKey()
    cachedKey = key
    return key
  }

  /// Mints a token for an enrolled device.
  public func issue(for device: EnrolledDevice) async throws -> AccessTokenGrant {
    let issuedAt = Int(clock.now.timeIntervalSince1970)
    let expiry = issuedAt + Int(Self.lifetime)
    // Sorted so the claim is deterministic; an unstable scope string would make otherwise
    // identical tokens differ and complicate any future caching.
    let scope = device.scopes.map(\.rawValue).sorted().joined(separator: " ")

    let claims = TokenClaims(
      sub: device.clientId,
      scope: scope,
      jti: UUID().uuidString,
      iat: issuedAt,
      exp: expiry,
      iss: Self.issuer
    )

    let header = ["alg": Self.algorithm, "typ": "JWT"]
    let encodedHeader = Base64URL.encode(
      try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    )
    let encodedClaims = Base64URL.encode(try JSONEncoder().encode(claims))
    let signingInput = "\(encodedHeader).\(encodedClaims)"

    let signature = try await signingKey().signature(for: Data(signingInput.utf8))
    return AccessTokenGrant(
      accessToken: "\(signingInput).\(Base64URL.encode(signature))",
      expiresIn: Int(Self.lifetime),
      scope: scope
    )
  }

  /// Verifies a token and returns its claims.
  ///
  /// Signature first, then the time window. Checking expiry before the signature would
  /// leak whether an unsigned, attacker-authored token had plausible timestamps.
  /// The one algorithm this server signs and accepts. Named once so the writer and the
  /// reader cannot drift apart.
  static let algorithm = "EdDSA"

  public func verify(_ token: String) async throws -> TokenClaims {
    // The split, the signature-first order and the header's `alg` are `CompactToken`'s, the
    // same rules the license verifier reads with.
    let parsed: CompactToken
    do { parsed = try CompactToken(parsing: token) } catch { throw TokenError.malformed }
    let key = try await signingKey().publicKey
    let claimData: Data
    do {
      claimData = try parsed.verifiedClaims(
        algorithm: Self.algorithm, invalidSignature: TokenError.badSignature
      ) { key.isValidSignature($0, for: $1) }
    } catch let error as TokenError {
      throw error
    } catch {
      throw TokenError.malformed
    }

    guard let claims = try? JSONDecoder().decode(TokenClaims.self, from: claimData) else {
      throw TokenError.malformed
    }
    guard claims.iss == Self.issuer else { throw TokenError.wrongIssuer }

    let moment = Int(clock.now.timeIntervalSince1970)
    // A small tolerance for clock skew between the machine that minted the token and the
    // one verifying it, which can be the same machine after an NTP correction.
    let skew = 60
    guard moment <= claims.exp + skew else { throw TokenError.expired }
    guard moment >= claims.iat - skew else { throw TokenError.notYetValid }

    return claims
  }
}

// MARK: - Key storage

/// Where the signing key comes from.
///
/// Behind a protocol because WHEN the key is created is the load-bearing part: under
/// `auth_mode = password` it must never be, so there is no new key material to protect and
/// no new attack surface. A provider that generated one eagerly would quietly break that.
public protocol SigningKeyProviding: Sendable {
  func signingKey() async throws -> Curve25519.Signing.PrivateKey
}

/// Keeps the key in the Keychain, creating it on first use.
public actor KeychainSigningKeyProvider: SigningKeyProviding {

  public static let keychainAccount = "auth.token_signing_key"

  private let secrets: any SecretStore

  public init(secrets: any SecretStore) {
    self.secrets = secrets
  }

  public func signingKey() async throws -> Curve25519.Signing.PrivateKey {
    if let existing = try secrets.get(Self.keychainAccount) {
      // A stored key that does not decode is reported, not regenerated. Regenerating it
      // signed every enrolled device out with nothing in any log to say why.
      guard let data = try? Ed25519Keys.rawBytes(fromBase64: existing),
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
      else { throw TokenError.unreadableSigningKey }
      return key
    }

    // First use, which under the default configuration never happens.
    let key = Curve25519.Signing.PrivateKey()
    try secrets.set(
      Self.keychainAccount,
      value: key.rawRepresentation.base64EncodedString()
    )
    return key
  }

  /// Whether a key has ever been created. Asserted by the default-off tests: a fresh
  /// install under `auth_mode = password` must have none.
  public func hasKey() -> Bool {
    ((try? secrets.get(Self.keychainAccount)) ?? nil) != nil
  }
}

/// The narrow slice of a secret store this module needs.
///

extension TokenError {
  public var code: String {
    switch self {
    case .malformed: "token.malformed"
    case .badSignature: "token.bad_signature"
    case .expired: "token.expired"
    case .notYetValid: "token.not_yet_valid"
    case .wrongIssuer: "token.wrong_issuer"
    case .unreadableSigningKey: "token.unreadable_signing_key"
    }
  }

  public var domain: String { "Auth" }

  /// Only the server's own fault interrupts anyone. The rest are a client presenting a bad
  /// token, which is the authentication path working, and alerting on it would let anyone
  /// on the internet raise notifications on someone's Mac.
  public var isUserFacing: Bool {
    switch self {
    case .unreadableSigningKey: return true
    default: return false
    }
  }

  public var title: String {
    switch self {
    case .unreadableSigningKey: "Token authentication cannot run"
    default: "A client presented an unusable token"
    }
  }

  public var body: String {
    switch self {
    case .malformed: "The token was not a well-formed token."
    case .badSignature: "The token's signature did not verify."
    case .expired: "The token has expired."
    case .notYetValid: "The token is not valid yet."
    case .wrongIssuer: "The token was issued by a different server."
    case .unreadableSigningKey:
      "The token signing key stored in the Keychain cannot be read, so this server cannot "
        + "issue or verify tokens. It has not been replaced, because a new key would sign "
        + "out every enrolled device."
    }
  }
}
