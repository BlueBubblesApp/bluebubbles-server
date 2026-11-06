//  SocketAuditingTests
//  A refused socket client is named in the audit log the way a refused HTTP client is.
//
//  Access control resolves NO identity for a trusted proxy that sent no forwarding header, and
//  the socket's audit records then named nobody, while the HTTP stage fell back to the peer.
//  The same wrong password was attributed on one transport and anonymous on the other, and
//  every unidentified socket client shared one repeat-limiter window.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAuth
import BBTestSupport
import Foundation
import Testing

@testable import BBSocketIO

@Suite("Socket auditing")
struct SocketAuditingTests {

  private func makeEngine(
    trusting proxies: Set<String>, auditor: CapturingAuditor<AuthenticationAuditEvent>
  )
    -> EngineIOServer
  {
    let digest = PasswordDigest("hunter2hunter2")
    return EngineIOServer(
      server: SocketServer(negotiator: .legacyOnly()),
      chain: {
        AuthenticationChain(schemes: [SocketHandshakeScheme(passwordProvider: { digest })])
      },
      accessControl: AccessControlService(
        policy: AccessControlPolicy(perClientThreshold: 99),
        trust: ProxyTrustPolicy(trustedProxies: proxies, permanentAllowlist: [])),
      auditor: auditor)
  }

  @Test("A wrong password from an ordinary peer names that peer")
  func resolvedPeer() async throws {
    let auditor = CapturingAuditor<AuthenticationAuditEvent>()
    let engine = makeEngine(trusting: [], auditor: auditor)
    _ = await engine.open(query: ["password": "wrong"], clientAddress: "198.51.100.20")
    let event = try #require(auditor.recorded.first)
    #expect(event.clientAddress == "198.51.100.20")
    #expect(event.transport == .socket)
  }

  @Test("A trusted proxy that sent no forwarding header is named, not recorded as nobody")
  func unresolvedFallsBackToThePeer() async throws {
    let auditor = CapturingAuditor<AuthenticationAuditEvent>()
    let engine = makeEngine(trusting: ["198.51.100.21"], auditor: auditor)
    _ = await engine.open(query: ["password": "wrong"], clientAddress: "198.51.100.21")
    let event = try #require(auditor.recorded.first)
    #expect(event.clientAddress == "198.51.100.21")
  }
}
