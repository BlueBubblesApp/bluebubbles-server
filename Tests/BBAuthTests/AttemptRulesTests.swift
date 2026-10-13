//  AttemptRulesTests
//  What each transport counts toward a block, and what it leaves in the audit log.
//
//  The HTTP stage and the socket engine both settle an attempt through `AuthenticationGate`,
//  and everything that differs between them is `AttemptRules`. These answers are observable:
//  they decide whether a client is blocked, and what an operator reads in the failure list
//  and the audit log. Pinned as a table so a change to one is a change somebody made on
//  purpose to this file.

import Testing

@testable import BBAuth

@Suite("Authentication attempt rules")
struct AttemptRulesTests {

  private let rejected = AuthenticationChain.Outcome.failed(.invalidCredential)
  private let serverFault = AuthenticationChain.Outcome.failed(.serverMisconfigured("none set"))

  @Test("A server fault counts against nobody and is never audited, on any transport")
  func serverFaultsAreNobodysFault() {
    for rules in [AttemptRules.http, .socketHandshake, .socketConnect] {
      #expect(!rules.counts(serverFault), "\(rules)")
      #expect(rules.auditKind(for: serverFault) == nil, "\(rules)")
      #expect(!rules.counts(.failed(.unavailable)), "\(rules)")
    }
  }

  @Test("A missing credential is a probe on HTTP and a counted refusal on the socket")
  func missingCredential() {
    #expect(!AttemptRules.http.counts(.noCredential))
    #expect(AttemptRules.http.auditKind(for: .noCredential) == .credentialMissing)

    #expect(AttemptRules.socketHandshake.counts(.noCredential))
    #expect(
      AttemptRules.socketHandshake.auditKind(for: .noCredential)
        == .credentialRejected(reason: "socket_handshake_rejected"))
    #expect(AttemptRules.socketConnect.counts(.noCredential))
    #expect(
      AttemptRules.socketConnect.auditKind(for: .noCredential)
        == .credentialRejected(reason: "socket_connect_rejected"))

    #expect(AttemptRules.socketGraceExpiry.counts(.noCredential))
    #expect(AttemptRules.socketGraceExpiry.auditKind(for: .noCredential) == .credentialMissing)
  }

  @Test("A wrong credential counts everywhere, and each transport names it its own way")
  func wrongCredential() {
    #expect(AttemptRules.http.counts(rejected))
    #expect(
      AttemptRules.http.auditKind(for: rejected)
        == .credentialRejected(reason: "auth.invalid_credential"))
    #expect(AttemptRules.http.failureReason(for: rejected) == "credential rejected")

    #expect(
      AttemptRules.socketHandshake.failureReason(for: rejected)
        == "socket handshake credential rejected")
    #expect(
      AttemptRules.socketConnect.failureReason(for: rejected)
        == "socket CONNECT credential rejected")
    #expect(
      AttemptRules.socketGraceExpiry.failureReason(for: .noCredential)
        == "socket handshake expired without a credential")
  }

  @Test("Success is never counted or audited")
  func successIsSilent() {
    let principal = AuthenticatedPrincipal(deviceID: nil, scopes: Scope.all, schemeID: "test")
    for rules in [AttemptRules.http, .socketHandshake, .socketConnect, .socketGraceExpiry] {
      #expect(!rules.counts(.authenticated(principal)))
      #expect(rules.auditKind(for: .authenticated(principal)) == nil)
    }
  }
}
