//  AuthenticationAuditingTests
//  The authentication stage tells the auditor about every refusal, against the route and never
//  the path.
//
//  The stage already records a failure for access control; the audit record is the second
//  reader of the same fact and is the one that leaves the machine, so it inherits the privacy
//  rule `FailureRecordPrivacyTests` pins: a route template, never the resolved path, which on
//  the chat and handle routes carries somebody's address.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAuth
import Foundation
import Testing

@testable import BBHTTPAPI

@Suite("Authentication stage auditing")
struct AuthenticationAuditingTests {

  private final class CapturingAuditor: AuthenticationAuditing, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AuthenticationAuditEvent] = []
    func record(_ event: AuthenticationAuditEvent) {
      lock.withLock { events.append(event) }
    }
    var recorded: [AuthenticationAuditEvent] { lock.withLock { events } }
  }

  private static let resolved = "/api/v1/chat/iMessage;-;%2B12025550143/read"
  private static let template = "/api/v1/chat/:guid/read"

  private func makeStage(_ auditor: CapturingAuditor, access: AccessControlService)
    -> AuthenticationStage
  {
    AuthenticationStage(
      chain: AuthenticationChain(
        schemes: [PasswordQueryScheme(passwordProvider: { PasswordDigest("correct-horse") })]
      ),
      accessControl: access,
      auditor: auditor
    )
  }

  @Test("A wrong password is recorded as a rejected credential on the route template")
  func rejectedCredential() async throws {
    let auditor = CapturingAuditor()
    let access = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 99),
      trust: ProxyTrustPolicy(trustedProxies: [], permanentAllowlist: []))
    let stage = makeStage(auditor, access: access)

    var request = APIRequestContext(
      method: .post, path: Self.resolved, queryParameters: ["password": "wrong"],
      peerAddress: "203.0.113.10", routeTemplate: Self.template)
    try await stage.admit(&request)
    await #expect(throws: (any Error).self) { try await stage.verifyCredential(&request) }

    let event = try #require(auditor.recorded.first)
    guard case .credentialRejected(let reason) = event.kind else {
      Issue.record("expected a rejected credential, got \(event.kind)")
      return
    }
    #expect(!reason.isEmpty)
    #expect(event.transport == .http)
    #expect(event.clientAddress == "203.0.113.10")
    #expect(event.route == Self.template)
    #expect(event.route?.contains("12025550143") == false)
  }

  @Test("A correct password records nothing: success is the transport record's job")
  func successIsSilent() async throws {
    let auditor = CapturingAuditor()
    let stage = makeStage(auditor, access: AccessControlService())
    var request = APIRequestContext(
      method: .post, path: Self.resolved, queryParameters: ["password": "correct-horse"],
      peerAddress: "203.0.113.10", routeTemplate: Self.template)
    try await stage.admit(&request)
    try await stage.verifyCredential(&request)
    #expect(auditor.recorded.isEmpty)
  }

  @Test("A blocked client is recorded as blocked before any credential is read")
  func blockedClient() async throws {
    let auditor = CapturingAuditor()
    let access = AccessControlService(
      trust: ProxyTrustPolicy(trustedProxies: [], permanentAllowlist: []))
    await access.blockPermanently(address: "203.0.113.10", reason: "test")
    let stage = makeStage(auditor, access: access)

    var request = APIRequestContext(
      method: .post, path: Self.resolved, queryParameters: ["password": "correct-horse"],
      peerAddress: "203.0.113.10", routeTemplate: Self.template)
    await #expect(throws: (any Error).self) { try await stage.admit(&request) }

    let event = try #require(auditor.recorded.first)
    #expect(event.kind == .blocked)
    #expect(event.clientAddress == "203.0.113.10")
    #expect(event.route == Self.template)
  }
}
