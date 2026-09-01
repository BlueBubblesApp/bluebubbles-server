//  TokenAuthService
//  Assembling token auth — and, under the default, deliberately not assembling it.
//
//  This type exists mainly to make "off" a single, testable fact rather than a convention
//  spread across four places. With `auth_mode = password`:
//
//    - the auth routes are NOT registered, so they 404 like any unknown path rather than
//      401ing — the route table stays identical to the Node server's, which the parity
//      harness asserts by diff,
//    - no signing key is generated, so there is no new key material to protect,
//    - no device store is touched, so no enrollment state exists,
//    - `BearerTokenScheme` is not constructed, so a Bearer header is ignored rather than
//      evaluated.
//
//  Turning it on is one setting with no rebuild. Turning it off again is equally clean,
//  because `password` never stopped working.
//
//  See `docs/AUTH.md`.

import BBSettings
import Foundation
import Logging

/// What the composition root needs to know to wire auth up.
public struct TokenAuthConfiguration: Sendable {
  public var mode: AuthMode
  /// Whether enrollment may be authenticated with the server password.
  ///
  /// The low-friction default: the client already has the password from today's setup
  /// flow, so enrollment needs no new user-facing step. A user who would rather not type
  /// the password into a client uses an enrollment code instead.
  public var allowsPasswordEnrollment: Bool

  public init(mode: AuthMode = .password, allowsPasswordEnrollment: Bool = true) {
    self.mode = mode
    self.allowsPasswordEnrollment = allowsPasswordEnrollment
  }

  /// The shipping default.
  public static let dormant = TokenAuthConfiguration(mode: .password)

  /// Whether any of the token machinery should exist at all.
  public var isTokenAuthEnabled: Bool { mode != .password }
}

public actor TokenAuthService {

  private let configuration: TokenAuthConfiguration
  private let logger: Logger
  /// Nil under the default. Their absence IS the feature — see the file comment.
  private let registry: DeviceRegistry?
  private let issuer: TokenIssuer?
  private let keyProvider: KeychainSigningKeyProvider?

  public init(
    configuration: TokenAuthConfiguration = .dormant,
    secrets: (any SecretStoring)? = nil,
    deviceStore: (any DeviceStoring)? = nil,
    logger: Logger = Logger(label: "bluebubbles.auth.token")
  ) {
    self.configuration = configuration
    self.logger = logger

    guard configuration.isTokenAuthEnabled, let secrets else {
      // Constructed as nothing. Not a disabled feature holding resources — an absent
      // one.
      self.registry = nil
      self.issuer = nil
      self.keyProvider = nil
      return
    }

    let provider = KeychainSigningKeyProvider(secrets: secrets)
    self.keyProvider = provider
    self.issuer = TokenIssuer(keyProvider: provider)
    self.registry = DeviceRegistry(
      store: deviceStore ?? InMemoryDeviceStore(), logger: logger
    )
  }

  public var isEnabled: Bool { configuration.isTokenAuthEnabled }
  public var mode: AuthMode { configuration.mode }

  /// The route groups to register, beyond the base table.
  ///
  /// Empty under the default, which is what makes the auth endpoints 404 rather than 401.
  /// The distinction matters: a 401 tells an attacker the endpoint exists.
  public var additionalRouteGroupNames: [String] {
    configuration.isTokenAuthEnabled ? ["Auth"] : []
  }

  /// Builds the authentication chain for the configured mode.
  public func chain(
    passwordProvider: @escaping @Sendable () async -> PasswordDigest?
  ) -> AuthenticationChain {
    guard let issuer, let registry, configuration.isTokenAuthEnabled else {
      // One scheme. BearerTokenScheme is not merely disabled here; it does not exist.
      return AuthenticationChain.forMode(.password, passwordProvider: passwordProvider)
    }
    return AuthenticationChain.forMode(
      configuration.mode,
      passwordProvider: passwordProvider,
      tokenScheme: BearerTokenScheme(issuer: issuer, registry: registry, logger: logger)
    )
  }

  // MARK: - Endpoints
  //
  // Each throws `.notEnabled` when off. That should be unreachable — the routes are not
  // registered — but a handler that answered anyway would silently undo the whole posture.

  public func issueEnrollmentCode() async throws -> EnrollmentCode {
    guard let registry else { throw EnrollmentError.notEnabled }
    return await registry.issueEnrollmentCode()
  }

  /// `POST /api/v1/auth/register`.
  ///
  /// Authenticated by either the server password or a one-time enrollment code — the caller
  /// has already established which, since the password check belongs to the existing
  /// scheme rather than being re-implemented here.
  public func enroll(
    name: String,
    platform: String,
    publicKey: Data? = nil,
    supportedCodecs: [String] = [],
    enrollmentCode: String? = nil,
    passwordAuthenticated: Bool = false
  ) async throws -> ClientCredentials {
    guard let registry else { throw EnrollmentError.notEnabled }

    // Exactly one of the two paths must have been satisfied. An enrollment endpoint is
    // necessarily reachable by an unenrolled caller, so this is the boundary.
    if let enrollmentCode {
      try await registry.consumeEnrollmentCode(enrollmentCode)
    } else {
      guard passwordAuthenticated, configuration.allowsPasswordEnrollment else {
        throw EnrollmentError.invalidEnrollmentCode
      }
    }

    let result = try await registry.enroll(
      name: name,
      platform: platform,
      publicKey: publicKey,
      supportedCodecs: supportedCodecs
    )
    return result.credentials
  }

  /// `POST /api/v1/auth/token` — `grant_type=client_credentials`.
  public func issueToken(
    clientId: String,
    clientSecret: String
  ) async throws -> AccessTokenGrant {
    guard let registry, let issuer else { throw EnrollmentError.notEnabled }
    let device = try await registry.authenticate(
      clientId: clientId, clientSecret: clientSecret
    )
    return try await issuer.issue(for: device)
  }

  /// `POST /api/v1/auth/rotate`.
  public func rotateSecret(
    clientId: String,
    currentSecret: String
  ) async throws -> ClientCredentials {
    guard let registry else { throw EnrollmentError.notEnabled }
    return try await registry.rotateSecret(clientId: clientId, currentSecret: currentSecret)
  }

  /// `POST /api/v1/auth/revoke`.
  public func revoke(deviceID: DeviceID) async throws {
    guard let registry else { throw EnrollmentError.notEnabled }
    try await registry.revoke(id: deviceID)
  }

  /// Backs the Devices screen.
  public func devices() async throws -> [EnrolledDevice] {
    guard let registry else { return [] }
    return try await registry.allDevices()
  }

  /// Whether a signing key has ever been created.
  ///
  /// Asserted by the default-off tests: a fresh install under `auth_mode = password` must
  /// have none, because generating one would create key material the user did not ask for
  /// and now has to protect.
  public func hasGeneratedSigningKey() async -> Bool {
    guard let keyProvider else { return false }
    return await keyProvider.hasKey()
  }
}
