//  MultiClientAccessTests
//  Concurrent clients are the normal case, not the exception.
//
//  A BlueBubbles install serves an Android phone, a Linux desktop and a Windows desktop at
//  the same time, all through one address. So every test here is about the rate limiter
//  NOT firing: the failure mode that matters is not "an attacker got through", it is "one
//  bad client, or one shared egress, took everybody else offline".
//
//  These complement AccessControlTests, which covers the counting itself.

import BBCore
import BBDiagnostics
import Foundation
import Testing

@testable import BBAuth

@Suite("Concurrent clients")
struct MultiClientAccessTests {

  private func service(
    clock: ManualClock,
    trust: ProxyTrustPolicy = ProxyTrustPolicy(trustedProxies: ["127.0.0.1"])
  ) -> AccessControlService {
    AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 3),
      trust: trust,
      clock: clock
    )
  }

  @Test("One client failing does not block any other client")
  func failuresAreIsolatedPerClient() async {
    let service = service(clock: ManualClock())

    let phone = ClientIdentity.address("198.51.100.10")
    let desktop = ClientIdentity.address("198.51.100.11")
    let laptop = ClientIdentity.address("198.51.100.12")

    for _ in 0..<6 {
      _ = await service.recordFailure(phone, path: "/api/v1/ping", reason: "bad")
    }

    guard case .blocked = await service.evaluate(phone) else {
      Issue.record("The offending client should be blocked")
      return
    }
    #expect(await service.evaluate(desktop) == .allow)
    #expect(await service.evaluate(laptop) == .allow)
  }

  @Test("Clients sharing a tunnel are told apart by the forwarded header")
  func tunnelledClientsAreAttributedIndividually() async {
    // The shipped topology: cloudflared/ngrok/zrok run on this machine, so every
    // tunnelled client's PEER address is 127.0.0.1. Without honoring the forwarded
    // header they would all share one counter, and one of them could block the rest.
    let service = service(clock: ManualClock())

    let bad = await service.identity(peerAddress: "127.0.0.1", forwardedFor: "198.51.100.10")
    let good = await service.identity(peerAddress: "127.0.0.1", forwardedFor: "198.51.100.11")
    #expect(bad != good)

    for _ in 0..<6 {
      _ = await service.recordFailure(bad, path: "/api/v1/ping", reason: "bad")
    }
    #expect(await service.evaluate(good) == .allow)
  }

  @Test("A tunnel that forwards nothing blocks nobody")
  func unattributableTrafficIsNeverBlocked() async {
    // The fail-open case, and the one that must never regress: if the proxy gives us no
    // way to tell clients apart, the ONLY safe answer is to block none of them. Blocking
    // the shared identity would take every client down at once.
    let service = service(clock: ManualClock())
    let anonymous = await service.identity(peerAddress: "127.0.0.1", forwardedFor: nil)
    #expect(anonymous == .unresolved)

    for _ in 0..<50 {
      _ = await service.recordFailure(anonymous, path: "/api/v1/ping", reason: "bad")
    }

    // Global throttling may engage at a much higher threshold, but nothing is ever
    // recorded as blocked — there is no address to lift a block from later.
    #expect(await service.blockedClients().isEmpty)
  }

  @Test("A reverse proxy is only believed once it is configured as trusted")
  func externalReverseProxyNeedsConfiguration() async {
    // Before `trusted_proxies` existed there was no way to declare an nginx on another
    // host, so every client behind it collapsed onto the proxy's address and three bad
    // passwords locked out the whole install.
    let untrusting = service(clock: ManualClock())
    let collapsed = await untrusting.identity(
      peerAddress: "10.1.1.5", forwardedFor: "198.51.100.10"
    )
    #expect(collapsed == .address("10.1.1.5"))

    let trusting = service(
      clock: ManualClock(),
      trust: ProxyTrustPolicy(trustedProxies: ["127.0.0.1", "10.1.1.0/24"])
    )
    let resolved = await trusting.identity(
      peerAddress: "10.1.1.5", forwardedFor: "198.51.100.10"
    )
    #expect(resolved == .address("198.51.100.10"))
  }

  @Test("A blocked client recovers on its own once the lockout expires")
  func blocksExpireWithoutIntervention() async {
    // Nobody is watching the Security page. A false positive that needs a human is an
    // outage; one that clears itself is an inconvenience.
    let clock = ManualClock()
    let service = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 3, baseLockout: .seconds(900)),
      trust: ProxyTrustPolicy(),
      clock: clock
    )
    let client = ClientIdentity.address("198.51.100.10")

    for _ in 0..<3 {
      _ = await service.recordFailure(client, path: "/api/v1/ping", reason: "bad")
    }
    guard case .blocked = await service.evaluate(client) else {
      Issue.record("Expected a block")
      return
    }

    clock.advance(by: 901)
    #expect(await service.evaluate(client) == .allow)
  }
}

/// Captures what would reach the notification drawer.
private actor RecordingAlerts: AlertRaising {
  private(set) var raised: [UserAlert] = []
  func raise(_ alert: UserAlert) async { raised.append(alert) }
  func raise(_ error: any BBError, actions: [AlertAction]) async {}
}

@Suite("Blocking is announced")
struct BlockAlertTests {

  @Test("Blocking a client raises a warning naming the address")
  func blockRaisesAnAlert() async {
    // A block is an event an operator has to see: it is either an attack worth knowing
    // about or their own client locked out by mistake, and both need the IP to act on.
    // A log line is not enough — nobody reads the log until something is already wrong.
    let alerts = RecordingAlerts()
    let service = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 2),
      clock: ManualClock(),
      alerts: alerts
    )

    for _ in 0..<2 {
      _ = await service.recordFailure(
        .address("198.51.100.10"), path: "/api/v1/ping", reason: "bad password"
      )
    }

    let raised = await alerts.raised
    #expect(raised.count == 1)
    guard let alert = raised.first else { return }
    #expect(alert.severity == .warning)
    // The address has to be readable in the notification itself, not only in the
    // structured context behind it.
    #expect(alert.body.contains("198.51.100.10"))
    #expect(alert.diagnostics?.context["address"] == .string("198.51.100.10"))
    // And the remedy travels with it, so a false positive is one click.
    #expect(alert.actions.contains(.unblock(address: "198.51.100.10")))
  }

  @Test("Each blocked address gets its own alert")
  func distinctAddressesAreDistinctAlerts() async {
    // Deduping by address rather than by code: two attackers are two facts. Deduping
    // them together would hide the second one entirely.
    let alerts = RecordingAlerts()
    let service = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 1),
      clock: ManualClock(),
      alerts: alerts
    )

    _ = await service.recordFailure(.address("198.51.100.10"), path: "/x", reason: "bad")
    _ = await service.recordFailure(.address("198.51.100.11"), path: "/x", reason: "bad")

    let keys = await alerts.raised.compactMap(\.dedupeKey)
    #expect(Set(keys).count == 2)
  }

  @Test("Throttling an unidentifiable source is announced too")
  func throttlingRaisesAnAlert() async {
    // Nothing can be blocked here, so without an alert a sustained attack behind a
    // proxy is completely silent.
    let alerts = RecordingAlerts()
    let service = AccessControlService(
      policy: AccessControlPolicy(globalThreshold: 3),
      clock: ManualClock(),
      alerts: alerts
    )

    for _ in 0..<3 {
      _ = await service.recordFailure(.unresolved, path: "/x", reason: "bad")
    }

    let raised = await alerts.raised
    #expect(raised.contains { $0.diagnostics?.code == "access_control.throttled" })
  }

  @Test("A sustained attack does not flood the drawer")
  func throttleAlertsAreDeduped() async {
    let alerts = RecordingAlerts()
    let service = AccessControlService(
      policy: AccessControlPolicy(globalThreshold: 3),
      clock: ManualClock(),
      alerts: alerts
    )

    for _ in 0..<200 {
      _ = await service.recordFailure(.unresolved, path: "/x", reason: "bad")
    }

    // Raised many times, but on one dedupe key — AlertCenter coalesces those into a
    // single row reading "occurred N times".
    let keys = await alerts.raised.compactMap(\.dedupeKey)
    #expect(Set(keys) == ["access_control.throttled"])
  }
}

@Suite("Trusted proxy grants")
struct TrustedProxyGrantTests {

  @Test("Setting a new tunnel address withdraws the previous grant")
  func tunnelGrantIsWithdrawn() async {
    // The grant carries the authority to set X-Forwarded-For. Leaving a stale one in
    // place means an address that USED to be the tunnel keeps the power to attribute
    // failures to any client it names — long after it stopped being ours.
    let service = AccessControlService(clock: ManualClock())

    await service.setActiveTunnelAddress("198.51.100.7")
    #expect(await service.activeTunnelAddress == "198.51.100.7")
    #expect(
      await service.identity(peerAddress: "198.51.100.7", forwardedFor: "203.0.113.1")
        == .address("203.0.113.1")
    )

    await service.setActiveTunnelAddress("198.51.100.8")
    #expect(await service.activeTunnelAddress == "198.51.100.8")

    // The old egress is now an ordinary client and its header means nothing.
    #expect(
      await service.identity(peerAddress: "198.51.100.7", forwardedFor: "203.0.113.1")
        == .address("198.51.100.7")
    )
  }

  @Test("Clearing the tunnel address removes the grant entirely")
  func tunnelGrantIsCleared() async {
    let service = AccessControlService(clock: ManualClock())
    await service.setActiveTunnelAddress("198.51.100.7")
    await service.setActiveTunnelAddress(nil)

    #expect(await service.activeTunnelAddress == nil)
    #expect(
      await service.identity(peerAddress: "198.51.100.7", forwardedFor: "203.0.113.1")
        == .address("198.51.100.7")
    )
  }

  @Test("Editing the trusted proxy list preserves the live tunnel grant")
  func updatingTrustKeepsTheTunnel() async {
    let service = AccessControlService(clock: ManualClock())
    await service.setActiveTunnelAddress("198.51.100.7")

    await service.update(trust: ProxyTrustPolicy(trustedProxies: ["127.0.0.1", "10.0.0.0/8"]))

    #expect(await service.activeTunnelAddress == "198.51.100.7")
    #expect(
      await service.identity(peerAddress: "198.51.100.7", forwardedFor: "203.0.113.1")
        == .address("203.0.113.1")
    )
    // And the newly declared block is honoured too.
    #expect(
      await service.identity(peerAddress: "10.2.3.4", forwardedFor: "203.0.113.2")
        == .address("203.0.113.2")
    )
  }

  @Test("Expired blocks are not retained forever")
  func expiredBlocksArePruned() async {
    // Every map keyed by client address is grown by whoever is attacking, and an IPv6
    // attacker has an unlimited supply of addresses to rotate through.
    let clock = ManualClock()
    let service = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 1, baseLockout: .seconds(60)),
      clock: clock
    )

    for octet in 1...20 {
      _ = await service.recordFailure(
        .address("198.51.100.\(octet)"), path: "/api/v1/ping", reason: "bad"
      )
    }
    #expect(await service.blockedClients().count == 20)

    clock.advance(by: 3600)
    // One more failure drives a prune; the expired entries go with it.
    _ = await service.recordFailure(.address("203.0.113.1"), path: "/x", reason: "bad")
    #expect(await service.blockedClients().count == 1)
  }
}

@Suite("The rate limiting toggle")
struct RateLimitToggleTests {

  @Test("Disabled means nobody is ever counted or blocked")
  func disabledAllowsEveryone() async {
    // A supported configuration, not a degraded one: a LAN-only install, or one behind a
    // proxy that already rate-limits, gains nothing here and can only lose clients to a
    // false positive.
    let service = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 2, isEnabled: false),
      clock: ManualClock()
    )
    let client = ClientIdentity.address("198.51.100.10")

    for _ in 0..<50 {
      #expect(await service.recordFailure(client, path: "/x", reason: "bad") == .allow)
    }
    #expect(await service.evaluate(client) == .allow)
    #expect(await service.blockedClients().isEmpty)
  }

  @Test("Disabling does not lift a block an administrator set by hand")
  func manualBlocksSurviveTheToggle() async {
    // The two are one feature for the AUTOMATIC half only. "Stop deciding this for me"
    // must not also mean "let the client I banned back in".
    let service = AccessControlService(
      policy: AccessControlPolicy(isEnabled: true), clock: ManualClock()
    )
    await service.blockPermanently(address: "198.51.100.10", reason: "abuse")

    await service.update(policy: AccessControlPolicy(isEnabled: false))

    guard case .blocked = await service.evaluate(.address("198.51.100.10")) else {
      Issue.record("An administrator's block was lifted by the automatic toggle")
      return
    }
    // While an ordinary client is unaffected.
    #expect(await service.evaluate(.address("198.51.100.11")) == .allow)
  }

  @Test("Re-enabling starts from a clean slate rather than a stale count")
  func reEnablingDoesNotReplayOldFailures() async {
    let clock = ManualClock()
    let service = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 3, isEnabled: false), clock: clock
    )
    let client = ClientIdentity.address("198.51.100.10")

    for _ in 0..<10 {
      _ = await service.recordFailure(client, path: "/x", reason: "bad")
    }
    await service.update(policy: AccessControlPolicy(perClientThreshold: 3, isEnabled: true))

    // Nothing was counted while it was off, so the client is not instantly over.
    #expect(await service.evaluate(client) == .allow)
  }
}
