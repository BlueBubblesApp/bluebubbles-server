//  BearerTokenScheme
//  The token half of the authentication chain.
//
//  Installed ONLY when `auth_mode` is `token` or `both`. Under the default, this type is
//  never constructed — so an `Authorization: Bearer <jwt>` header is not evaluated and
//  rejected, it falls through to the password scheme and is treated as a candidate password.
//  That is the intended behaviour: the token system does not exist until it is enabled.
//
//  See `docs/AUTH.md`.

import Foundation
import Logging

public struct BearerTokenScheme: AuthenticationScheme {

  public let id = "bearer-token"

  private let issuer: TokenIssuer
  private let registry: DeviceRegistry
  private let logger: Logger

  public init(
    issuer: TokenIssuer,
    registry: DeviceRegistry,
    logger: Logger = Logger(label: "bluebubbles.auth.bearer")
  ) {
    self.issuer = issuer
    self.registry = registry
    self.logger = logger
  }

  public func authenticate(
    _ presentation: CredentialPresentation
  ) async throws -> AuthenticatedPrincipal? {
    guard let token = Self.token(in: presentation) else {
      // No credential of THIS kind. Returning nil rather than throwing is what lets the
      // chain fall through to the password scheme under `both`.
      return nil
    }

    let claims: TokenClaims
    do {
      claims = try await issuer.verify(token)
    } catch TokenError.expired {
      throw AuthenticationFailure.expired
    } catch {
      throw AuthenticationFailure.invalidCredential
    }

    // Stateless verification got us the claims; this is the one database read, and it is
    // what makes revocation take effect immediately rather than at token expiry. Without
    // it a revoked device keeps working for up to an hour.
    guard let device = try? await registry.device(clientId: claims.sub) else {
      throw AuthenticationFailure.invalidCredential
    }
    guard !device.isRevoked else { throw AuthenticationFailure.revoked }

    await registry.noteActivity(clientId: claims.sub)

    // Scopes come from the DEVICE, not from the token. A token minted before scopes were
    // narrowed must not keep the wider set until it expires.
    return AuthenticatedPrincipal(
      deviceID: device.id,
      scopes: device.scopes,
      schemeID: id
    )
  }

  /// Finds a bearer token in the header or in the Socket.IO handshake.
  ///
  /// Socket.IO v4 carries credentials in its native `auth: {token}` field, which arrives as
  /// a query parameter here — the same chain has to serve both transports, and today they
  /// have separate and subtly different code paths.
  static func token(in presentation: CredentialPresentation) -> String? {
    if let header = presentation.authorizationHeader {
      let parts = header.split(separator: " ", maxSplits: 1)
      if parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame {
        let candidate = String(parts[1]).trimmingCharacters(in: .whitespaces)
        // A JWT has three dot-separated parts. Requiring that shape is what keeps a
        // `Bearer <password>` header — which is valid under the password scheme —
        // from being consumed here and failing.
        if candidate.split(separator: ".").count == 3 { return candidate }
      }
    }

    if let handshake = presentation.queryParameters["auth_token"]
      ?? presentation.queryParameters["access_token"],
      handshake.split(separator: ".").count == 3
    {
      return handshake
    }
    return nil
  }
}

// MARK: - Scope enforcement

public enum ScopeEnforcement {

  /// Checks a principal against a route's declared scope.
  ///
  /// Declared as route metadata rather than run as a second middleware pass, so a route
  /// cannot be added without stating what it needs — the omission would be a compile error
  /// in the route table rather than an unprotected endpoint.
  public static func authorize(
    _ principal: AuthenticatedPrincipal,
    requires scope: Scope
  ) throws {
    // The shared-password principal holds every scope, so this is a no-op under the
    // default configuration — which is why enabling scopes cannot break an existing
    // client.
    guard principal.hasScope(scope) else {
      throw AuthenticationFailure.insufficientScope(scope)
    }
  }
}
