//  AccessControlAuditingTests
//  Every change to who may connect is reported to the auditor, and nothing else is.
//
//  The access controller knows when a client was blocked, for how long and why, and the audit
//  log is the only durable place that knowledge goes: the blocklist itself expires. So each
//  administered change and each automatic block hands over a value, and an unblock of an
//  address that was not blocked hands over nothing, because nothing changed.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BBAuth

@Suite("Access control auditing")
struct AccessControlAuditingTests {

  private final class CapturingAuditor: AccessControlAuditing, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AccessControlAuditEvent] = []
    func record(_ event: AccessControlAuditEvent) {
      lock.withLock { events.append(event) }
    }
    var recorded: [AccessControlAuditEvent] { lock.withLock { events } }
  }

  private func makeService(_ auditor: CapturingAuditor, threshold: Int = 1) -> AccessControlService
  {
    AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: threshold),
      trust: ProxyTrustPolicy(trustedProxies: [], permanentAllowlist: []),
      auditor: auditor
    )
  }

  @Test("Crossing the failure threshold reports the block with its counts and expiry")
  func automaticBlock() async {
    let auditor = CapturingAuditor()
    let service = makeService(auditor, threshold: 2)
    let client = ClientIdentity.address("203.0.113.9")

    await service.recordFailure(client, path: "/api/v1/ping", reason: "bad")
    #expect(auditor.recorded.isEmpty, "one failure is not a block")
    await service.recordFailure(client, path: "/api/v1/ping", reason: "bad")

    guard case .clientBlocked(let address, let reason, let failures, let offences, let expiresAt)? =
      auditor.recorded.first
    else {
      Issue.record("expected a block, got \(auditor.recorded)")
      return
    }
    #expect(address == "203.0.113.9")
    #expect(reason == "bad")
    #expect(failures == 2)
    #expect(offences == 1)
    #expect(expiresAt > Date())
  }

  @Test("Unblocking reports once, and only when something was blocked")
  func unblock() async {
    let auditor = CapturingAuditor()
    let service = makeService(auditor)
    await service.unblock(address: "203.0.113.9")
    #expect(auditor.recorded.isEmpty, "nothing was blocked, so nothing changed")

    await service.recordFailure(.address("203.0.113.9"), path: "/x", reason: "bad")
    await service.unblock(address: "203.0.113.9")
    #expect(auditor.recorded.last == .clientUnblocked(address: "203.0.113.9"))
  }

  @Test("A permanent block, the allowlist and clearing every block each report")
  func administeredChanges() async {
    let auditor = CapturingAuditor()
    let service = makeService(auditor)

    await service.blockPermanently(address: "198.51.100.7", reason: "abuse")
    #expect(
      auditor.recorded.last == .clientBlockedPermanently(address: "198.51.100.7", reason: "abuse"))

    let entry = await service.allow(cidr: "192.168.1.0/24", note: "LAN")
    #expect(auditor.recorded.last == .clientAllowlisted(cidr: "192.168.1.0/24", note: "LAN"))

    if let entry {
      await service.disallow(id: entry.id)
      #expect(auditor.recorded.last == .allowlistEntryRemoved(cidr: "192.168.1.0/24"))
    } else {
      Issue.record("the allowlist entry was not created")
    }

    await service.clearAllBlocks()
    #expect(auditor.recorded.last == .blocksCleared(count: 1))
  }

  @Test("Unattributable failures past the global threshold report the throttle")
  func throttle() async {
    let auditor = CapturingAuditor()
    var policy = AccessControlPolicy(perClientThreshold: 99)
    policy.globalThreshold = 2
    let service = AccessControlService(
      policy: policy, trust: ProxyTrustPolicy(trustedProxies: [], permanentAllowlist: []),
      auditor: auditor)

    await service.recordFailure(.unresolved, path: "/x", reason: "bad")
    await service.recordFailure(.unresolved, path: "/x", reason: "bad")
    #expect(auditor.recorded.contains(.loginsThrottled(failureCount: 2)))
  }
}
