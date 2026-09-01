//  GoogleTokenProvider
//  Service-account JWT -> OAuth2 access token, cached.
//
//  This is what `firebase-admin` does internally and what there is no Swift equivalent of, so
//  it is done directly: build a JWT, sign it RS256 with the service-account key, exchange it
//  at Google's token endpoint for a bearer token, and reuse that token until it is nearly
//  expired.
//
//  See `docs/EVENTS.md`.

import BBCore
import Crypto
import Foundation
import Logging
import _CryptoExtras

public enum GoogleAuthError: BBError, Equatable {
  case invalidPrivateKey(reason: String)
  case tokenRequestFailed(status: UInt, body: String)
  case malformedTokenResponse
  /// The browser-obtained token has expired and cannot be renewed. Only reachable from the
  /// interactive setup flow.
  case interactiveTokenExpired
}

/// OAuth scopes the server needs.
public enum GoogleScope {
  /// Sending through FCM HTTP v1.
  public static let firebaseMessaging = "https://www.googleapis.com/auth/firebase.messaging"
  /// Reading and writing Firestore documents.
  public static let datastore = "https://www.googleapis.com/auth/datastore"
  /// Realtime Database access.
  public static let firebaseDatabase = "https://www.googleapis.com/auth/firebase.database"
  /// Project and ruleset administration.
  public static let cloudPlatform = "https://www.googleapis.com/auth/cloud-platform"
  /// Reading the user's email, needed by the interactive setup flow.
  public static let userinfoEmail = "https://www.googleapis.com/auth/userinfo.email"

  /// What the running server needs. Deliberately not `cloud-platform` alone: a token that
  /// can do everything is one worth stealing, and these are the operations actually used.
  public static let serverRuntime = [
    firebaseMessaging, datastore, firebaseDatabase, cloudPlatform,
  ]
}

/// An access token and when it stops being usable.
public struct AccessToken: Sendable, Equatable {
  public let value: String
  public let expiresAt: Date

  public init(value: String, expiresAt: Date) {
    self.value = value
    self.expiresAt = expiresAt
  }

  /// Refreshed early rather than on expiry: a token that expires mid-flight produces a 401
  /// on a notification that then looks like a delivery failure.
  public func isUsable(at moment: Date = Date(), leeway: TimeInterval = 300) -> Bool {
    expiresAt.timeIntervalSince(moment) > leeway
  }
}

/// Exchanges a signed assertion for an access token. Abstracted so the JWT construction can
/// be tested without reaching Google.
public protocol TokenExchanging: Sendable {
  func exchange(assertion: String, tokenURI: String) async throws -> AccessToken
}

/// Supplies bearer tokens to `GoogleAPIClient`.
///
/// Two implementations, and the split is the whole reason this protocol exists. The RUNNING
/// server authenticates as a service account and can mint a fresh token whenever it likes.
/// SETUP authenticates as the USER, through the browser consent flow, because creating a
/// project is something only a human account is allowed to do — a service account for a
/// project that does not exist yet is a contradiction. Before this seam existed
/// `GoogleAPIClient` named `GoogleTokenProvider` concretely, so `FirebaseProvisioner` could
/// not be handed a user token and therefore could not be constructed at all. It was written,
/// tested, and reachable from nothing.
public protocol AccessTokenProviding: Sendable {
  func token() async throws -> AccessToken
  /// Drops any cached token, so the next call re-mints rather than replaying one Google
  /// has already refused.
  func invalidate() async
}

/// A token obtained once, interactively, that cannot be renewed.
///
/// The implicit OAuth flow returns no refresh token — that is what "implicit" means — so
/// when this expires the only recovery is to send the user back through the browser. It
/// reports expiry as an error rather than pretending, because a provisioning run that fails
/// half way with `401` from Google is far harder to explain than one that says "your sign-in
/// expired, sign in again".
public actor StaticTokenProvider: AccessTokenProviding {

  private let stored: AccessToken

  public init(_ token: AccessToken) {
    self.stored = token
  }

  public init(value: String, expiresIn: TimeInterval = 3600) {
    self.stored = AccessToken(value: value, expiresAt: Date().addingTimeInterval(expiresIn))
  }

  public func token() async throws -> AccessToken {
    // No leeway: unlike a mintable token there is nothing to refresh early FOR, and
    // refusing a token that still has four minutes on it would abandon a provisioning
    // run that would have finished.
    guard stored.isUsable(leeway: 0) else { throw GoogleAuthError.interactiveTokenExpired }
    return stored
  }

  public func invalidate() async {}
}

public actor GoogleTokenProvider: AccessTokenProviding {

  private let account: ServiceAccount
  private let scopes: [String]
  private let exchanger: any TokenExchanging
  private let logger: Logger
  private var cached: AccessToken?
  /// In-flight refresh, so a burst of sends produces one token request rather than twenty.
  private var refreshTask: Task<AccessToken, any Error>?

  public init(
    account: ServiceAccount,
    scopes: [String] = GoogleScope.serverRuntime,
    exchanger: any TokenExchanging,
    logger: Logger = Logger(label: "bluebubbles.push.auth")
  ) {
    self.account = account
    self.scopes = scopes
    self.exchanger = exchanger
    self.logger = logger
  }

  public func token() async throws -> AccessToken {
    try await token(now: Date())
  }

  /// A usable token, minted or reused.
  ///
  /// `now` is injectable so the cache-reuse and early-refresh boundaries can be asserted
  /// without sleeping through an hour.
  public func token(now: Date) async throws -> AccessToken {
    if let cached, cached.isUsable(at: now) { return cached }

    // Coalesced: without this, ten concurrent notifications on a cold cache each mint a
    // JWT and each hit the token endpoint.
    if let refreshTask { return try await refreshTask.value }

    let task = Task { [account, scopes, exchanger] in
      let assertion = try Self.assertion(for: account, scopes: scopes, now: now)
      return try await exchanger.exchange(assertion: assertion, tokenURI: account.tokenURI)
    }
    refreshTask = task
    defer { refreshTask = nil }

    let token = try await task.value
    cached = token
    return token
  }

  /// Drops the cached token. Used when Google rejects it, so the next call re-mints rather
  /// than replaying a token the server already refused.
  public func invalidate() {
    cached = nil
  }

  // MARK: - JWT

  /// Builds and signs the assertion Google exchanges for a token.
  ///
  /// RS256 over `base64url(header) + "." + base64url(claims)`, per RFC 7523. The claims are
  /// exactly the five Google requires; extra ones are rejected rather than ignored.
  static func assertion(
    for account: ServiceAccount,
    scopes: [String],
    now: Date = Date()
  ) throws -> String {
    let issuedAt = Int(now.timeIntervalSince1970)
    // One hour is Google's maximum. Shorter buys nothing: the assertion is used once,
    // immediately, and never stored.
    let expiry = issuedAt + 3600

    let header: [String: String] = [
      "alg": "RS256",
      "typ": "JWT",
      "kid": account.privateKeyId,
    ]
    let claims: [String: Any] = [
      "iss": account.clientEmail,
      "scope": scopes.joined(separator: " "),
      "aud": account.tokenURI,
      "iat": issuedAt,
      "exp": expiry,
    ]

    let encodedHeader = try base64URL(
      JSONSerialization.data(
        withJSONObject: header, options: [.sortedKeys]
      ))
    let encodedClaims = try base64URL(
      JSONSerialization.data(
        withJSONObject: claims, options: [.sortedKeys]
      ))
    let signingInput = "\(encodedHeader).\(encodedClaims)"

    let key: _RSA.Signing.PrivateKey
    do {
      // Google issues a PKCS#8 PEM, which this reads directly — the alternative is
      // unwrapping the PKCS#8 envelope by hand to get at the PKCS#1 key.
      key = try _RSA.Signing.PrivateKey(pemRepresentation: account.privateKey)
    } catch {
      throw GoogleAuthError.invalidPrivateKey(reason: String(describing: error))
    }

    // `.insecurePKCS1v1_5` despite the name. RS256 IS RSASSA-PKCS1-v1_5 with SHA-256 —
    // that is what the algorithm identifier means, and what Google's token endpoint
    // verifies against. swift-crypto labels the padding "insecure" to steer new designs
    // toward PSS; here the wire format is not ours to choose.
    let signature = try key.signature(
      for: Data(signingInput.utf8), padding: .insecurePKCS1v1_5
    )
    return "\(signingInput).\(base64URL(signature.rawRepresentation))"
  }

  /// base64url, unpadded — JWT's encoding, which is not plain base64.
  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

extension GoogleAuthError {
  public var code: String {
    switch self {
    case .invalidPrivateKey: "google.invalid_private_key"
    case .tokenRequestFailed: "google.token_request_failed"
    case .malformedTokenResponse: "google.malformed_token_response"
    case .interactiveTokenExpired: "google.interactive_token_expired"
    }
  }

  public var domain: String { "Push" }

  /// Only the one with a remedy. A transient token request failure retries on its own.
  public var isUserFacing: Bool {
    switch self {
    case .invalidPrivateKey, .interactiveTokenExpired: true
    case .tokenRequestFailed, .malformedTokenResponse: false
    }
  }

  public var title: String {
    switch self {
    case .invalidPrivateKey: "The Firebase key could not be used"
    case .interactiveTokenExpired: "Sign in to Google again"
    default: "Google would not issue a token"
    }
  }

  public var body: String {
    switch self {
    case .invalidPrivateKey(let reason):
      "The private key in the service account file could not be parsed: \(reason)"
    case .tokenRequestFailed(let status, let body):
      "Google returned \(status): \(body)"
    case .malformedTokenResponse:
      "Google returned a token response this server could not read."
    case .interactiveTokenExpired:
      "The Google sign-in used for setup has expired. Signing in again restores it."
    }
  }

  public var context: [String: DiagnosticValue] {
    if case .tokenRequestFailed(let status, _) = self { return ["status": .int(Int(status))] }
    return [:]
  }
}
