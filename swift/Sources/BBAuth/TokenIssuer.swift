//  TokenIssuer
//  Short-lived Ed25519 access tokens.
//
//  Why no refresh token
//  --------------------
//  Because the client already holds a durable, device-specific secret from enrollment, it can
//  re-mint an access token whenever it likes. A refresh token would be a second long-lived
//  credential doing the job the first one already does — that is a simplification over a
//  user-facing OAuth flow rather than a compromise. Access tokens live an hour and are cheap
//  to replace; revoking a device is deleting one row.
//
//  Why Ed25519 rather than HMAC
//  ----------------------------
//  Verification is stateless — no database read on the hot path — and the verifying key is
//  public. That matters for what comes later: a proxy or a companion process could verify a
//  token without being trusted to MINT one, which a shared HMAC secret cannot express.
//
//  All of it is dormant by default: with `auth_mode = password` no signing key is ever
//  generated. See `docs/AUTH.md`.

import BBCore
import Crypto
import Foundation

public enum TokenError: BBError, Equatable {
  case malformed
  case badSignature
  case expired
  case notYetValid
  case wrongIssuer
  case missingSigningKey
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
  /// A unique id per token. Not used for revocation — that is what the device row is for —
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
  /// until it expires — revoking the device stops new ones being issued, but cannot recall
  /// one already in flight.
  public static let lifetime: TimeInterval = 3600
  public static let issuer = "bluebubbles-server"

  private let keyProvider: any SigningKeyProviding
  private var cachedKey: Curve25519.Signing.PrivateKey?

  public init(keyProvider: any SigningKeyProviding) {
    self.keyProvider = keyProvider
  }

  private func signingKey() async throws -> Curve25519.Signing.PrivateKey {
    if let cachedKey { return cachedKey }
    let key = try await keyProvider.signingKey()
    cachedKey = key
    return key
  }

  /// Mints a token for an enrolled device.
  public func issue(
    for device: EnrolledDevice,
    now: Date = Date()
  ) async throws -> AccessTokenGrant {
    let issuedAt = Int(now.timeIntervalSince1970)
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

    let header = ["alg": "EdDSA", "typ": "JWT"]
    let encodedHeader = Self.base64URL(
      try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    )
    let encodedClaims = Self.base64URL(try JSONEncoder().encode(claims))
    let signingInput = "\(encodedHeader).\(encodedClaims)"

    let signature = try await signingKey().signature(for: Data(signingInput.utf8))
    return AccessTokenGrant(
      accessToken: "\(signingInput).\(Self.base64URL(signature))",
      expiresIn: Int(Self.lifetime),
      scope: scope
    )
  }

  /// Verifies a token and returns its claims.
  ///
  /// Signature first, then the time window. Checking expiry before the signature would
  /// leak whether an unsigned, attacker-authored token had plausible timestamps.
  public func verify(_ token: String, now: Date = Date()) async throws -> TokenClaims {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { throw TokenError.malformed }

    let signingInput = "\(parts[0]).\(parts[1])"
    guard let signature = Self.decodeBase64URL(String(parts[2])),
      let claimData = Self.decodeBase64URL(String(parts[1]))
    else { throw TokenError.malformed }

    let key = try await signingKey().publicKey
    guard key.isValidSignature(signature, for: Data(signingInput.utf8)) else {
      throw TokenError.badSignature
    }

    guard let claims = try? JSONDecoder().decode(TokenClaims.self, from: claimData) else {
      throw TokenError.malformed
    }
    guard claims.iss == Self.issuer else { throw TokenError.wrongIssuer }

    let moment = Int(now.timeIntervalSince1970)
    // A small tolerance for clock skew between the machine that minted the token and the
    // one verifying it — which can be the same machine after an NTP correction.
    let skew = 60
    guard moment <= claims.exp + skew else { throw TokenError.expired }
    guard moment >= claims.iat - skew else { throw TokenError.notYetValid }

    return claims
  }

  /// The public half, for anything that should verify without being able to mint.
  public func verifyingKey() async throws -> Data {
    try await signingKey().publicKey.rawRepresentation
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decodeBase64URL(_ text: String) -> Data? {
    var padded =
      text
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while padded.count % 4 != 0 { padded += "=" }
    return Data(base64Encoded: padded)
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

  private let secrets: any SecretStoring

  public init(secrets: any SecretStoring) {
    self.secrets = secrets
  }

  public func signingKey() async throws -> Curve25519.Signing.PrivateKey {
    if let existing = try secrets.get(Self.keychainAccount),
      let data = Data(base64Encoded: existing),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    {
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

  public func destroyKey() throws {
    try secrets.delete(Self.keychainAccount)
  }
}

/// The narrow slice of a secret store this module needs.
///
/// Declared here rather than importing BBSettings' `SecretStore` so that BBAuth does not take
/// a dependency on the settings layer purely to name a protocol.
public protocol SecretStoring: Sendable {
  func get(_ key: String) throws -> String?
  func set(_ key: String, value: String) throws
  func delete(_ key: String) throws
}

extension TokenError {
  public var code: String {
    switch self {
    case .malformed: "token.malformed"
    case .badSignature: "token.bad_signature"
    case .expired: "token.expired"
    case .notYetValid: "token.not_yet_valid"
    case .wrongIssuer: "token.wrong_issuer"
    case .missingSigningKey: "token.missing_signing_key"
    }
  }

  public var domain: String { "Auth" }

  /// Only the server's own fault interrupts anyone. The rest are a client presenting a bad
  /// token, which is the authentication path working — and alerting on it would let anyone
  /// on the internet raise notifications on someone's Mac.
  public var isUserFacing: Bool {
    if case .missingSigningKey = self { return true }
    return false
  }

  public var title: String {
    switch self {
    case .missingSigningKey: "Token authentication cannot run"
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
    case .missingSigningKey:
      "No signing key is available, so this server cannot issue or verify tokens. "
        + "Authentication falls back to the server password."
    }
  }
}
