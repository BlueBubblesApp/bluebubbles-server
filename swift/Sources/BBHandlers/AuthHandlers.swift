//  AuthHandlers
//  The four token-auth endpoints.
//
//  Registered ONLY when `auth_mode` is not `password`. Under the default they are not merely
//  guarded — they are absent from the router, so they 404 like any unknown path. A 401 would
//  tell an attacker the endpoint exists, and it would make the route table differ from the
//  Node server's, which the parity harness diffs strictly.
//
//  See `docs/AUTH.md`.

import BBAuth
import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation

public enum AuthHandlers {

  /// Registers the four handlers. Called only when token auth is enabled.
  public static func register(
    into registry: inout HandlerRegistry, context: some TokenAuthProviding
  ) {
    registry.register(.authRegister) { request in
      try await self.enroll(request, context: context)
    }
    registry.register(.authToken) { request in
      try await self.token(request, context: context)
    }
    registry.register(.authRotate) { request in
      try await self.rotate(request, context: context)
    }
    registry.register(.authRevoke) { request in
      try await self.revoke(request, context: context)
    }
  }

  /// `POST /api/v1/auth/register`.
  ///
  /// Reachable by an unenrolled caller by necessity — that is what enrollment means — so
  /// the credential check is the boundary, and it accepts exactly two things: the server
  /// password, or a one-time code.
  private static func enroll(
    _ request: APIRequestContext,
    context: some TokenAuthProviding
  ) async throws -> RouteResult {
    let values = try request.values()
    guard let name = values["device_name"]?.stringValue, !name.isEmpty else {
      throw BadRequest("device_name is required")
    }
    let platform = values["platform"]?.stringValue ?? "unknown"

    // The request reached a handler, so the auth chain already accepted it — which under
    // `both` means the password was valid. An enrollment code is the alternative for a
    // user who would rather not type the password into a client.
    let code = values["enrollment_code"]?.stringValue
    let passwordAuthenticated = request.principal != nil && code == nil

    let capabilities = TargetCapabilitiesBridge.parse(values.raw)

    do {
      let credentials = try await context.tokenAuth.enroll(
        name: name,
        platform: platform,
        publicKey: capabilities.publicKey,
        supportedCodecs: capabilities.codecs,
        enrollmentCode: code,
        passwordAuthenticated: passwordAuthenticated
      )
      // Returned once and never again — the secret is stored hashed, so the server
      // itself cannot reissue it. A client that loses it re-enrolls.
      return .data(
        .object([
          "client_id": .string(credentials.clientId),
          "client_secret": .string(credentials.clientSecret),
        ]))
    } catch EnrollmentError.invalidEnrollmentCode {
      throw Unauthorized("that enrollment code is not valid")
    } catch EnrollmentError.enrollmentCodeExpired {
      throw Unauthorized("that enrollment code has expired")
    }
  }

  /// `POST /api/v1/auth/token` — `grant_type=client_credentials`.
  private static func token(
    _ request: APIRequestContext,
    context: some TokenAuthProviding
  ) async throws -> RouteResult {
    let values = try request.values()

    // OAuth 2.0 names the grant, and refusing an unknown one matters: a client sending
    // `password` should be told it is unsupported rather than silently handed a token.
    let grant = values["grant_type"]?.stringValue ?? "client_credentials"
    guard grant == "client_credentials" else {
      throw BadRequest("unsupported grant_type: \(grant)")
    }
    guard let clientId = values["client_id"]?.stringValue,
      let clientSecret = values["client_secret"]?.stringValue
    else {
      throw BadRequest("client_id and client_secret are required")
    }

    do {
      let grant = try await context.tokenAuth.issueToken(
        clientId: clientId, clientSecret: clientSecret
      )
      return .data(
        .object([
          "access_token": .string(grant.accessToken),
          "token_type": .string(grant.tokenType),
          "expires_in": .int(grant.expiresIn),
          "scope": .string(grant.scope),
        ]))
    } catch {
      // Deliberately one message for every failure. Distinguishing "unknown client"
      // from "wrong secret" enumerates valid client ids for free.
      throw Unauthorized("those credentials were not accepted")
    }
  }

  /// `POST /api/v1/auth/rotate`, authenticated with the CURRENT secret.
  private static func rotate(
    _ request: APIRequestContext,
    context: some TokenAuthProviding
  ) async throws -> RouteResult {
    let values = try request.values()
    guard let clientId = values["client_id"]?.stringValue,
      let currentSecret = values["client_secret"]?.stringValue
    else {
      throw BadRequest("client_id and client_secret are required")
    }

    do {
      let credentials = try await context.tokenAuth.rotateSecret(
        clientId: clientId, currentSecret: currentSecret
      )
      return .data(
        .object([
          "client_id": .string(credentials.clientId),
          "client_secret": .string(credentials.clientSecret),
        ]))
    } catch {
      throw Unauthorized("those credentials were not accepted")
    }
  }

  /// `POST /api/v1/auth/revoke`. Requires `server:admin`.
  private static func revoke(
    _ request: APIRequestContext,
    context: some TokenAuthProviding
  ) async throws -> RouteResult {
    let values = try request.values()
    guard let deviceID = values["device_id"]?.stringValue else {
      throw BadRequest("device_id is required")
    }
    try await context.tokenAuth.revoke(deviceID: DeviceID(deviceID))
    return .data(nil)
  }
}

/// Turns a registration body into codec capability.
///
/// Shared between enrollment and FCM registration because the two carry the same two fields —
/// the difference is which table the row lands in, not what they mean.
enum TargetCapabilitiesBridge {
  static func parse(_ body: JSONValue) -> (publicKey: Data?, codecs: [String]) {
    let codecs = body["supportedCodecs"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let key = body["publicKey"]?.stringValue
      .flatMap { Data(base64Encoded: $0) }
      // An X25519 key is exactly 32 bytes. Rejecting the wrong length here means the
      // failure surfaces at registration rather than at the first send, where it would
      // look like a delivery problem.
      .flatMap { $0.count == 32 ? $0 : nil }
    return (key, codecs)
  }
}
