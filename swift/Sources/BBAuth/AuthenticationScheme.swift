//  AuthenticationScheme
//  Authentication as a chain of schemes rather than one middleware function.
//
//  The default configuration installs exactly one scheme — PasswordQueryScheme — and behaves
//  identically to the current AuthMiddleware. Everything else in BBAuth is dormant code
//  behind `auth_mode`, and the tests assert it stays that way: the token routes must 404
//  rather than 401, no key material may be generated, and a Bearer header must be IGNORED
//  rather than rejected.
//
//  See `docs/AUTH.md`.

import BBCore
import BBSettings
import Foundation

// `PasswordPolicy` lives in BBSettings so it can be attached to the `password` setting's own
// validator — the only place every write to a password passes through. Re-exported because it is
// conceptually part of the auth surface and callers import BBAuth for it.
@_exported import struct BBSettings.PasswordPolicy

// MARK: - Principal

public enum Scope: String, Sendable, CaseIterable, Codable {
  case messagesRead = "messages:read"
  case messagesWrite = "messages:write"
  case chatsWrite = "chats:write"
  case attachmentsRead = "attachments:read"
  case serverAdmin = "server:admin"

  public static let all = Set(Scope.allCases)
}

public struct DeviceID: Hashable, Sendable, Codable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct AuthenticatedPrincipal: Sendable {
  /// nil for the shared-password principal, which has no device identity. That is the
  /// whole limitation token auth exists to fix, and why a leaked password today can only
  /// be revoked by changing it for everyone.
  public let deviceID: DeviceID?
  public let scopes: Set<Scope>
  public let schemeID: String

  public init(deviceID: DeviceID?, scopes: Set<Scope>, schemeID: String) {
    self.deviceID = deviceID
    self.scopes = scopes
    self.schemeID = schemeID
  }

  public func hasScope(_ scope: Scope) -> Bool { scopes.contains(scope) }
}

// MARK: - Credential presentation

/// What a scheme is handed. Kept transport-agnostic so the socket handshake can authenticate
/// through the same chain as HTTP — today the two have separate, subtly different code paths.
public struct CredentialPresentation: Sendable {
  public let queryParameters: [String: String]
  public let authorizationHeader: String?
  public let clientAddress: String?
  public let path: String

  public init(
    queryParameters: [String: String] = [:],
    authorizationHeader: String? = nil,
    clientAddress: String? = nil,
    path: String = ""
  ) {
    self.queryParameters = queryParameters
    self.authorizationHeader = authorizationHeader
    self.clientAddress = clientAddress
    self.path = path
  }
}

public protocol AuthenticationScheme: Sendable {
  var id: String { get }
  /// Returns nil when this scheme finds no credential of its kind, which passes the
  /// request to the next scheme. Throwing means a credential was PRESENT and WRONG — the
  /// distinction the rate limiter counts on, since a missing credential is not an attempt.
  func authenticate(_ presentation: CredentialPresentation) async throws -> AuthenticatedPrincipal?
}

public enum AuthenticationFailure: BBError, Equatable {
  /// A credential was supplied and did not match. Counts against the rate limiter.
  case invalidCredential
  /// No password is configured server-side. A server misconfiguration, not a client one,
  /// so it must NOT count against the client.
  case serverMisconfigured(String)
  case expired
  case revoked
  case insufficientScope(Scope)

  /// Whether this failure should increment the client's failure counter.
  public var countsAsAttempt: Bool {
    switch self {
    case .invalidCredential, .expired, .revoked: true
    case .serverMisconfigured, .insufficientScope: false
    }
  }
}

// MARK: - Password (default)

/// The shipping scheme: `?guid=` / `?password=` / `?token=`, or an Authorization header.
///
/// Two changes from the current middleware, neither observable to a client:
///   - Comparison is constant-time against a Keychain-held SecureString, replacing
///     `safeTrim(a) !== safeTrim(b)` which leaks length and prefix through timing.
///   - `Authorization: Bearer <password>` and `Authorization: Basic` are accepted, so a
///     client can stop putting the password in a URL that lands in tunnel and proxy logs.
///     Query params keep working unchanged; nothing is forced onto the header.
public struct PasswordQueryScheme: AuthenticationScheme {

  public let id = "password"

  private let passwordProvider: @Sendable () async -> PasswordDigest?

  public init(passwordProvider: @escaping @Sendable () async -> PasswordDigest?) {
    self.passwordProvider = passwordProvider
  }

  /// Checked in this order, first present one wins. `guid` first is historical — it was
  /// the original name and predates there being a password at all.
  static let parameterNames = ["guid", "password", "token"]

  public func authenticate(
    _ presentation: CredentialPresentation
  ) async throws -> AuthenticatedPrincipal? {
    guard let supplied = Self.extractCredential(from: presentation) else {
      // No credential of our kind. Not a failure — the chain continues, and with only
      // this scheme installed the caller turns it into a 401.
      return nil
    }

    guard let password = await passwordProvider() else {
      // nil is specifically "the Keychain could not be read" — distinct from the
      // unconfigured case below. Naming the Keychain matters: the old message said
      // "database" for both, which sent anyone debugging this at the wrong subsystem.
      throw AuthenticationFailure.serverMisconfigured(
        "The server password could not be read from the Keychain"
      )
    }
    guard !password.isEmpty else {
      throw AuthenticationFailure.serverMisconfigured(
        "No server password is configured"
      )
    }

    // Trimmed on both sides, matching safeTrim. Clients have shipped trailing
    // whitespace, so tightening this would lock them out.
    guard password.constantTimeEquals(supplied.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      throw AuthenticationFailure.invalidCredential
    }

    // The shared password grants everything. Scopes only become meaningful with
    // per-device credentials.
    return AuthenticatedPrincipal(deviceID: nil, scopes: Scope.all, schemeID: id)
  }

  static func extractCredential(from presentation: CredentialPresentation) -> String? {
    for name in parameterNames {
      if let value = presentation.queryParameters[name], !value.isEmpty {
        return value
      }
    }

    guard let header = presentation.authorizationHeader else { return nil }

    if let token = header.stripping(prefix: "Bearer "), !token.isEmpty {
      return token
    }
    if let encoded = header.stripping(prefix: "Basic "),
      let decoded = Data(base64Encoded: encoded),
      let pair = String(data: decoded, encoding: .utf8)
    {
      // Basic is `user:password`; the username is ignored, as clients send anything.
      return pair.split(separator: ":", maxSplits: 1).last.map(String.init)
    }
    return nil
  }
}

extension String {
  fileprivate func stripping(prefix: String) -> String? {
    guard lowercased().hasPrefix(prefix.lowercased()) else { return nil }
    return String(dropFirst(prefix.count))
  }
}

// MARK: - Socket handshake

/// The socket accepts only `password` and `guid` — never `token` — and URL-decodes the value
/// first. Both differences from HTTP are real and shipped, so they are reproduced rather
/// than harmonised.
public struct SocketHandshakeScheme: AuthenticationScheme {

  public let id = "socket-handshake"

  private let inner: PasswordQueryScheme

  public init(passwordProvider: @escaping @Sendable () async -> PasswordDigest?) {
    self.inner = PasswordQueryScheme(passwordProvider: passwordProvider)
  }

  /// Rewrites a handshake query into the credentials the socket actually accepts.
  ///
  /// Exposed as a static, and used by `SocketServer.authenticate` as well as by this
  /// scheme, so the rule has ONE implementation — and it has to be the one that RUNS. If
  /// the transport hands the raw query to the HTTP chain instead, which accepts `token` and
  /// does not decode, a password containing an `@` or a space locks the user out of the
  /// socket while working fine over HTTP: close to undiagnosable from a client.
  public static func normalize(query: [String: String]) -> [String: String] {
    guard let raw = query["password"] ?? query["guid"], !raw.isEmpty else { return [:] }

    // NOT decoded here. The transport parsed the raw query through
    // `QueryStringDecoder`, so this value has already been decoded exactly once.
    //
    // Decoding again is precisely the bug the current server has — it calls `decodeURI`
    // on a value engine.io has already decoded — and it corrupts any password containing
    // a literal `%` followed by two hex digits. The rule is that decoding happens once,
    // at the edge, and every layer above treats the value as opaque.
    return ["password": raw]
  }

  public func authenticate(
    _ presentation: CredentialPresentation
  ) async throws -> AuthenticatedPrincipal? {
    let normalized = Self.normalize(query: presentation.queryParameters)
    guard !normalized.isEmpty else { return nil }

    return try await inner.authenticate(
      CredentialPresentation(
        queryParameters: normalized,
        clientAddress: presentation.clientAddress,
        path: presentation.path
      )
    )
  }
}

// MARK: - The chain

// `AuthMode` is declared in BBSettings, not here.
//
// It has to be a `SettingValue` to be storable, and BBSettings cannot import BBAuth — the
// dependency runs the other way. Declaring it in both places compiled fine and then made
// every use site ambiguous the moment something imported both, which is exactly what the
// composition root does.
//
//   `password` — the default, and the only mode any shipping client needs.
//   `token`    — Bearer only.
//   `both`     — the migration path: accept either, and log which clients still use the
//                query param so a future decision has data behind it.

public struct AuthenticationChain: Sendable {

  private let schemes: [any AuthenticationScheme]

  public init(schemes: [any AuthenticationScheme]) {
    self.schemes = schemes
  }

  /// Builds the chain for a mode.
  ///
  /// Note what `password` produces: a one-element array. BearerTokenScheme is not
  /// constructed, so a Bearer header naming a real token is not evaluated — it falls
  /// through to PasswordQueryScheme, which treats it as a candidate password and fails.
  /// That is the intended behavior: the token system does not exist until it is enabled.
  public static func forMode(
    _ mode: AuthMode,
    passwordProvider: @escaping @Sendable () async -> PasswordDigest?,
    tokenScheme: (any AuthenticationScheme)? = nil
  ) -> AuthenticationChain {
    switch mode {
    case .password:
      AuthenticationChain(schemes: [PasswordQueryScheme(passwordProvider: passwordProvider)])
    case .token:
      AuthenticationChain(schemes: tokenScheme.map { [$0] } ?? [])
    case .both:
      AuthenticationChain(
        schemes: [tokenScheme, PasswordQueryScheme(passwordProvider: passwordProvider)]
          .compactMap { $0 }
      )
    }
  }

  /// Result of running the chain. `.noCredential` is distinct from `.failed` because only
  /// the latter counts against the rate limiter.
  public enum Outcome: Sendable {
    case authenticated(AuthenticatedPrincipal)
    case noCredential
    case failed(AuthenticationFailure)
  }

  public func authenticate(_ presentation: CredentialPresentation) async -> Outcome {
    var lastFailure: AuthenticationFailure?

    for scheme in schemes {
      do {
        if let principal = try await scheme.authenticate(presentation) {
          return .authenticated(principal)
        }
      } catch let failure as AuthenticationFailure {
        // Keep going: under `both`, a bad Bearer token should still let a valid
        // query-param password through rather than short-circuiting.
        lastFailure = failure
      } catch {
        lastFailure = .invalidCredential
      }
    }

    if let lastFailure { return .failed(lastFailure) }
    return .noCredential
  }
}

extension AuthenticationFailure {
  public var code: String {
    switch self {
    case .invalidCredential: "auth.invalid_credential"
    case .serverMisconfigured: "auth.server_misconfigured"
    case .expired: "auth.expired"
    case .revoked: "auth.revoked"
    case .insufficientScope: "auth.insufficient_scope"
    }
  }

  public var domain: String { "Auth" }

  public var isUserFacing: Bool {
    // The server's own misconfiguration is the only one worth interrupting over. The rest
    // are reachable by anyone who can reach the port, so alerting on them would hand a
    // stranger a way to fill someone's screen with notifications.
    if case .serverMisconfigured = self { return true }
    return false
  }

  public var title: String { "A client could not authenticate" }

  public var body: String {
    switch self {
    case .invalidCredential: "The credential presented was not accepted."
    case .serverMisconfigured(let reason): reason
    case .expired: "The credential presented has expired."
    case .revoked: "The credential presented has been revoked."
    case .insufficientScope(let scope): "The credential is not permitted to \(scope.rawValue)."
    }
  }
}
