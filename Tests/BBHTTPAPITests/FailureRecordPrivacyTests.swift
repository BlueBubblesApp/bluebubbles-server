//  FailureRecordPrivacyTests
//  An authentication failure is recorded against the ROUTE, never against the path sent.
//
//  `/api/v1/chat/iMessage;-;+12025550143/read` is a real request shape and the middle segment
//  is somebody's phone number. It was going into `AuthFailureRecord.path`, which
//  `GET /api/v1/server/security/failures` serialises verbatim and the Security page renders
//  verbatim — so an unauthenticated caller, anyone who can reach the port, chose text that
//  appeared on the operator's screen and in the server's own API.
//
//  The stage forty lines above already declines to put that value in a log, and says why in
//  place. Nothing carried the rule as far as the record, and no scanner could:
//  `LogRedactionPolicyTests` reads `logger.<level>(…)` calls and this is not one. So it is
//  pinned here instead.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAuth
import Foundation
import Testing

@testable import BBHTTPAPI

@Suite("Authentication failure records carry no address")
struct FailureRecordPrivacyTests {

  /// The shape of the leak: a resolved path with an address in it.
  private static let resolved = "/api/v1/chat/iMessage;-;%2B12025550143/read"
  private static let template = "/api/v1/chat/:guid/read"

  private func context(routeTemplate: String?) -> APIRequestContext {
    APIRequestContext(
      method: .post,
      path: Self.resolved,
      peerAddress: "203.0.113.10",
      routeTemplate: routeTemplate
    )
  }

  @Test("A failure is recorded against the route template, not the path")
  func recordsTheTemplate() {
    #expect(context(routeTemplate: Self.template).auditPath == Self.template)
  }

  /// The important half. A context that never saw the router must not fall back to the
  /// caller's path — that fallback IS the leak, and it is the obvious thing to write.
  @Test("A context with no route falls back to a placeholder, never to the path")
  func noFallbackToThePath() {
    let audit = context(routeTemplate: nil).auditPath
    #expect(audit == "(unmatched)")
    #expect(!audit.contains("12025550143"))
    #expect(!audit.contains("iMessage;-;"))
  }

  /// End to end through the stage that actually records, so this cannot pass because the
  /// property is right and the call site still reads `.path`.
  @Test("The recorded failure the Security page reads carries no address")
  func recordedFailureIsClean() async throws {
    let access = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 99),
      trust: ProxyTrustPolicy(trustedProxies: [], permanentAllowlist: [])
    )
    let stage = AuthenticationStage(
      chain: AuthenticationChain(
        schemes: [PasswordQueryScheme(passwordProvider: { PasswordDigest("correct-horse") })]
      ),
      accessControl: access
    )

    var request = APIRequestContext(
      method: .post,
      path: Self.resolved,
      queryParameters: ["password": "wrong"],
      peerAddress: "203.0.113.10",
      routeTemplate: Self.template
    )
    try await stage.admit(&request)
    await #expect(throws: (any Error).self) { try await stage.verifyCredential(&request) }

    let failures = await access.failures()
    let recorded = try #require(failures.first)
    #expect(recorded.path == Self.template)
    #expect(!recorded.path.contains("12025550143"))
  }
}
