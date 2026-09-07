//  AccessControlTests
//  The highest-value test in this module is the tunnel footgun.
//
//  Rate limiting behind Cloudflare/ngrok/zrok is the change most likely to cause an outage
//  rather than prevent one: attribute a failure to the tunnel egress and one attacker locks
//  out every legitimate client at once. These tests exist so that failure mode cannot ship.

import BBCore
import Foundation
import Testing

@testable import BBAuth

@Suite("Client identity resolution")
struct ClientIdentityTests {

  @Test("A direct connection is attributed to its peer")
  func directConnection() {
    let trust = ProxyTrustPolicy()
    #expect(
      trust.resolve(peerAddress: "203.0.113.9", forwardedFor: nil) == .address("203.0.113.9")
    )
  }

  @Test("A forwarding header from an untrusted peer is ignored")
  func untrustedForwardingHeaderIsIgnored() {
    // Otherwise anyone can attribute their failures to someone else's address and get a
    // third party blocked, which turns rate limiting into a denial-of-service primitive.
    let trust = ProxyTrustPolicy()
    let identity = trust.resolve(
      peerAddress: "203.0.113.9", forwardedFor: "198.51.100.1"
    )
    #expect(identity == .address("203.0.113.9"))
  }

  @Test("A trusted proxy's forwarding header names the client")
  func trustedProxyHeader() {
    let trust = ProxyTrustPolicy(trustedProxies: ["127.0.0.1"])
    let identity = trust.resolve(peerAddress: "127.0.0.1", forwardedFor: "198.51.100.1")
    #expect(identity == .address("198.51.100.1"))
  }

  @Test("The rightmost untrusted hop wins, not the leftmost")
  func rightmostUntrustedHop() {
    // The leftmost entry is whatever the client sent, so it is attacker-controlled. Only
    // the entries appended by proxies we trust mean anything.
    let trust = ProxyTrustPolicy(trustedProxies: ["127.0.0.1", "10.0.0.1"])
    let identity = trust.resolve(
      peerAddress: "127.0.0.1",
      forwardedFor: "1.2.3.4, 198.51.100.1, 10.0.0.1"
    )
    #expect(identity == .address("198.51.100.1"))
  }

  @Test("A trusted proxy with no forwarding header is unresolved, never the proxy")
  func trustedProxyWithoutHeader() {
    // THE case. Attributing this to the proxy is what locks out every client.
    let trust = ProxyTrustPolicy(trustedProxies: ["127.0.0.1"])
    #expect(trust.resolve(peerAddress: "127.0.0.1", forwardedFor: nil) == .unresolved)
  }

  @Test("IPv4-mapped IPv6 and bare IPv4 are the same client")
  func addressNormalization() {
    #expect(ProxyTrustPolicy.normalize("::ffff:1.2.3.4") == "1.2.3.4")
    #expect(ProxyTrustPolicy.normalize("[2001:db8::1]") == "2001:db8::1")
    #expect(ProxyTrustPolicy.normalize("fe80::1%en0") == "fe80::1")
  }
}

@Suite("Rate limiting")
struct RateLimitingTests {

  private func service(
    clock: ManualClock,
    policy: AccessControlPolicy = AccessControlPolicy(perClientThreshold: 3)
  ) -> AccessControlService {
    AccessControlService(
      policy: policy,
      trust: ProxyTrustPolicy(trustedProxies: ["127.0.0.1"]),
      clock: clock
    )
  }

  @Test("A client is blocked after crossing the failure threshold")
  func blocksAfterThreshold() async {
    let clock = ManualClock()
    let service = service(clock: clock)
    let client = ClientIdentity.address("203.0.113.9")

    for _ in 0..<2 {
      #expect(await service.recordFailure(client, path: "/api/v1/ping", reason: "bad") == .allow)
    }
    let decision = await service.recordFailure(client, path: "/api/v1/ping", reason: "bad")
    guard case .blocked = decision else {
      Issue.record("Expected a block, got \(decision)")
      return
    }
    guard case .blocked = await service.evaluate(client) else {
      Issue.record("The block did not persist")
      return
    }
  }

  @Test("Successful requests are never counted")
  func successesDoNotCount() async {
    // Some clients poll hard with valid credentials. Counting successes would throttle
    // exactly the clients that are behaving.
    let clock = ManualClock()
    let service = service(clock: clock)
    let client = ClientIdentity.address("203.0.113.9")

    for _ in 0..<100 {
      await service.recordSuccess(client)
    }
    #expect(await service.evaluate(client) == .allow)
  }

  @Test("A success resets the failure counter")
  func successResetsTheCounter() async {
    // A client retrying a stale password recovers the moment it is corrected, rather
    // than creeping toward a block over hours of intermittent failures.
    let clock = ManualClock()
    let service = service(clock: clock)
    let client = ClientIdentity.address("203.0.113.9")

    await service.recordFailure(client, path: "/x", reason: "bad")
    await service.recordFailure(client, path: "/x", reason: "bad")
    await service.recordSuccess(client)
    #expect(await service.recordFailure(client, path: "/x", reason: "bad") == .allow)
    #expect(await service.evaluate(client) == .allow)
  }

  @Test("Blocks expire on their own")
  func blocksExpire() async {
    // Automatic blocks are never permanent, so a false positive self-heals even if
    // nobody ever opens the Security page.
    let clock = ManualClock()
    let service = service(
      clock: clock,
      policy: AccessControlPolicy(perClientThreshold: 1, baseLockout: .seconds(600))
    )
    let client = ClientIdentity.address("203.0.113.9")

    await service.recordFailure(client, path: "/x", reason: "bad")
    guard case .blocked = await service.evaluate(client) else {
      Issue.record("Expected a block")
      return
    }

    clock.advance(by: 601.0)
    #expect(await service.evaluate(client) == .allow)
  }

  @Test("Repeat offences escalate the lockout")
  func lockoutEscalates() async {
    let clock = ManualClock()
    let service = service(
      clock: clock,
      policy: AccessControlPolicy(perClientThreshold: 1, baseLockout: .seconds(100))
    )
    let client = ClientIdentity.address("203.0.113.9")

    await service.recordFailure(client, path: "/x", reason: "bad")
    let firstBlock = await service.blockedClients().first
    let firstDuration = firstBlock.flatMap { block in
      block.expiresAt.map { $0.timeIntervalSince(block.blockedAt) }
    }

    clock.advance(by: 101.0)
    await service.recordFailure(client, path: "/x", reason: "bad")
    let secondBlock = await service.blockedClients().first
    let secondDuration = secondBlock.flatMap { block in
      block.expiresAt.map { $0.timeIntervalSince(block.blockedAt) }
    }

    #expect(firstDuration == 100)
    #expect(secondDuration == 200)
  }

  @Test("Unresolved clients are throttled, never blocked")
  func unresolvedClientsAreNotBlocked() async {
    // The tunnel case. There is nobody to block but the proxy, and blocking the proxy is
    // the outage this whole design exists to avoid.
    let clock = ManualClock()
    let service = service(
      clock: clock,
      policy: AccessControlPolicy(perClientThreshold: 1, globalThreshold: 5)
    )

    for _ in 0..<4 {
      #expect(await service.recordFailure(.unresolved, path: "/x", reason: "bad") == .allow)
    }
    #expect(await service.recordFailure(.unresolved, path: "/x", reason: "bad") == .throttled)
    #expect(await service.blockedClients().isEmpty)
  }

  @Test("The active tunnel address can never be blocked")
  func tunnelAddressIsUnblockable() async {
    let clock = ManualClock()
    let service = service(
      clock: clock, policy: AccessControlPolicy(perClientThreshold: 1)
    )
    await service.setActiveTunnelAddress("198.51.100.7")
    let tunnel = ClientIdentity.address("198.51.100.7")

    for _ in 0..<50 {
      #expect(await service.recordFailure(tunnel, path: "/x", reason: "bad") == .allow)
    }
    #expect(await service.evaluate(tunnel) == .allow)
    #expect(await service.blockedClients().isEmpty)
  }

  @Test("Loopback is never blocked")
  func loopbackIsNeverBlocked() async {
    let clock = ManualClock()
    let service = service(clock: clock, policy: AccessControlPolicy(perClientThreshold: 1))
    let local = ClientIdentity.address("127.0.0.1")

    for _ in 0..<20 {
      await service.recordFailure(local, path: "/x", reason: "bad")
    }
    #expect(await service.evaluate(local) == .allow)
  }

  @Test("Unblocking takes effect immediately")
  func unblockIsImmediate() async {
    let clock = ManualClock()
    let service = service(clock: clock, policy: AccessControlPolicy(perClientThreshold: 1))
    let client = ClientIdentity.address("203.0.113.9")

    await service.recordFailure(client, path: "/x", reason: "bad")
    await service.unblock(address: "203.0.113.9")
    #expect(await service.evaluate(client) == .allow)
    #expect(await service.blockedClients().isEmpty)
  }

  @Test("An allowlisted CIDR is never blocked")
  func allowlistedRange() async {
    let clock = ManualClock()
    let service = service(clock: clock, policy: AccessControlPolicy(perClientThreshold: 1))
    await service.allow(cidr: "192.168.1.0/24", note: "home")
    let client = ClientIdentity.address("192.168.1.50")

    for _ in 0..<10 {
      await service.recordFailure(client, path: "/x", reason: "bad")
    }
    #expect(await service.evaluate(client) == .allow)
  }

  @Test("Private ranges are not allowlisted by default")
  func privateRangesAreNotTrustedByDefault() async {
    // A LAN is not automatically friendly. The one-click toggle exists for users who
    // decide otherwise.
    let clock = ManualClock()
    let service = service(clock: clock, policy: AccessControlPolicy(perClientThreshold: 1))
    let client = ClientIdentity.address("192.168.1.50")

    await service.recordFailure(client, path: "/x", reason: "bad")
    guard case .blocked = await service.evaluate(client) else {
      Issue.record("Expected a private-range client to be blockable by default")
      return
    }

    await service.trustLocalNetwork(true)
    await service.unblock(address: "192.168.1.50")
    await service.recordFailure(client, path: "/x", reason: "bad")
    #expect(await service.evaluate(client) == .allow)
  }

  @Test("Failure history is bounded")
  func failureHistoryIsBounded() async {
    // An attacker controls how fast rows arrive here, so this must not be a growth path.
    let clock = ManualClock()
    let service = service(
      clock: clock,
      policy: AccessControlPolicy(perClientThreshold: 1_000_000, failureHistoryLimit: 10)
    )
    for index in 0..<100 {
      await service.recordFailure(
        .address("203.0.113.\(index % 250)"), path: "/x", reason: "bad"
      )
    }
    #expect(await service.failures(limit: 1000).count == 10)
  }
}

@Suite("CIDR matching")
struct CIDRTests {

  @Test("IPv4 ranges")
  func ipv4() {
    #expect(CIDR.matches(address: "192.168.1.50", pattern: "192.168.1.0/24"))
    #expect(!CIDR.matches(address: "192.168.2.50", pattern: "192.168.1.0/24"))
    #expect(CIDR.matches(address: "10.5.6.7", pattern: "10.0.0.0/8"))
    #expect(!CIDR.matches(address: "11.5.6.7", pattern: "10.0.0.0/8"))
    // A prefix that is not a byte boundary, which is where naive implementations break.
    #expect(CIDR.matches(address: "172.16.0.1", pattern: "172.16.0.0/12"))
    #expect(CIDR.matches(address: "172.31.255.254", pattern: "172.16.0.0/12"))
    #expect(!CIDR.matches(address: "172.32.0.1", pattern: "172.16.0.0/12"))
  }

  @Test("IPv6 ranges")
  func ipv6() {
    #expect(CIDR.matches(address: "fd00::1", pattern: "fc00::/7"))
    #expect(!CIDR.matches(address: "2001:db8::1", pattern: "fc00::/7"))
    #expect(CIDR.matches(address: "2001:db8::1", pattern: "2001:db8::/32"))
  }

  @Test("A bare address matches exactly")
  func exactMatch() {
    #expect(CIDR.matches(address: "192.168.1.50", pattern: "192.168.1.50"))
    #expect(!CIDR.matches(address: "192.168.1.51", pattern: "192.168.1.50"))
  }
}
