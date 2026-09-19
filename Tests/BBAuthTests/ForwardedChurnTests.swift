//  ForwardedChurnTests
//  The per-address failure budget is keyed on an address the peer DECLARED.
//
//  Behind a trusted proxy, `X-Forwarded-For` is that declaration, and on the default policy
//  loopback is a trusted proxy — it has to be, because the bundled tunnels all run on this
//  machine and connect over it. So anything that can reach the listener from loopback can
//  vary the header per request, get a fresh `failureTimes` bucket every time, and never
//  reach `perClientThreshold` at all. Not a bypass of the password, but a bypass of the
//  thing that bounds guessing at it.
//
//  Two properties have to hold at once, and the second is the harder one:
//
//    1. Churn stops being believed. The distinguishing signal is DISTINCT ADDRESSES, not
//       failure volume: a password change storming twenty real clients is twenty addresses
//       that each stop counting once they block, while rotation is unbounded addresses that
//       never block.
//    2. Real clients are not collateral. This file's sibling, `MultiClientAccessTests`,
//       exists because "one bad client took everybody offline" is the worse failure — so a
//       tripped peer must DEGRADE to `.unresolved`, the route already designed for "no way
//       to tell these clients apart", and never block anyone.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import BBDiagnostics
import BBSettings
import Foundation
import Testing

@testable import BBAuth

@Suite("Forwarded-address churn")
struct ForwardedChurnTests {

  private let loopback = "127.0.0.1"

  private func service(
    churnLimit: Int = 8,
    clock: ManualClock
  ) -> AccessControlService {
    AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 3, forwardedChurnLimit: churnLimit),
      trust: ProxyTrustPolicy(trustedProxies: [loopback]),
      clock: clock
    )
  }

  /// One forged attempt: resolve as the middleware does, then record as it does.
  private func attempt(
    _ service: AccessControlService, claiming address: String
  ) async -> AccessDecision {
    let identity = await service.identity(peerAddress: loopback, forwardedFor: address)
    return await service.recordFailure(
      identity, path: "/api/v1/ping", reason: "bad", peerAddress: loopback)
  }

  // MARK: - The hole

  @Test("Rotating the forwarded address stops buying a fresh budget")
  func rotationIsBounded() async {
    // Before the ceiling this loop ran for ever: every address is new, so every address is
    // one failure short of nothing, and `evaluate` answered `.allow` indefinitely.
    let service = service(clock: ManualClock())

    for index in 0..<8 { _ = await attempt(service, claiming: "198.51.100.\(index)") }

    // The peer's header is no longer believed, so the next forged address does not resolve
    // to itself any more.
    let identity = await service.identity(peerAddress: loopback, forwardedFor: "198.51.100.99")
    #expect(identity == .unresolved, "a tripped peer must stop attributing, got \(identity)")
  }

  @Test("Once tripped, the attempts land under the global ceiling instead")
  func trippedTrafficIsThrottledGlobally() async {
    // The point of degrading to `.unresolved` rather than inventing new enforcement: that
    // path already counts into one bucket and throttles at `globalThreshold`.
    let clock = ManualClock()
    let service = AccessControlService(
      policy: AccessControlPolicy(
        perClientThreshold: 3, globalThreshold: 4, forwardedChurnLimit: 2),
      trust: ProxyTrustPolicy(trustedProxies: [loopback]),
      clock: clock
    )

    var decisions: [AccessDecision] = []
    for index in 0..<10 {
      decisions.append(await attempt(service, claiming: "198.51.100.\(index)"))
    }

    #expect(
      decisions.contains { if case .throttled = $0 { return true } else { return false } },
      "rotation must eventually reach the global ceiling")
  }

  @Test("An allowlisted claim is counted too, or the allowlist is the bypass")
  func allowlistedClaimsStillCount() async {
    // `isAlwaysAllowed` returns before the per-address counter, so an attacker who names an
    // allowlisted address is never counted and never blocked. That is precisely what
    // `trust_local_network` handed out by default: it allowlists the private ranges, and
    // the claim is a header. Churn is recorded BEFORE that check for this reason.
    let clock = ManualClock()
    let service = service(churnLimit: 4, clock: clock)
    _ = await service.allow(cidr: "10.0.0.0/8", note: "LAN")

    for index in 0..<4 { _ = await attempt(service, claiming: "10.0.0.\(index)") }

    let identity = await service.identity(peerAddress: loopback, forwardedFor: "10.0.0.99")
    #expect(identity == .unresolved, "an allowlisted claim must still count toward churn")
  }

  // MARK: - Not collateral

  @Test("A real multi-client install is untouched")
  func realClientsDoNotTrip() async {
    // The half that keeps this safe. The default ceiling is generous against the largest
    // plausible install; here the point is the SHAPE — a handful of real clients failing
    // repeatedly is few addresses and many failures, which must never trip a limit aimed at
    // many addresses and few failures.
    let service = service(churnLimit: 8, clock: ManualClock())

    for _ in 0..<20 {
      for client in 0..<3 { _ = await attempt(service, claiming: "198.51.100.\(client)") }
    }

    let identity = await service.identity(peerAddress: loopback, forwardedFor: "198.51.100.1")
    #expect(identity == .address("198.51.100.1"), "three real clients must still be attributed")
  }

  @Test("A tripped peer blocks nobody")
  func trippingNeverBlocks() async {
    // `.unresolved` is deliberately unblockable: the only address to blame would be the
    // proxy every client shares, which is the self-inflicted outage this file exists to
    // avoid. See MultiClientAccessTests.
    let service = service(churnLimit: 3, clock: ManualClock())
    for index in 0..<12 { _ = await attempt(service, claiming: "198.51.100.\(index)") }

    let decision = await service.evaluate(.unresolved)
    #expect(
      { if case .blocked = decision { return false } else { return true } }(),
      "the unresolved path must never block, got \(decision)")
  }

  @Test("A direct client is never affected by churn")
  func directPeersAreNotSubjectToThis() async {
    // The ceiling is about addresses that were CLAIMED. A direct peer cannot vary its own
    // address without actually holding those addresses, and counting it would let one
    // busy LAN subnet silently disable attribution for everybody.
    let service = service(churnLimit: 3, clock: ManualClock())

    for index in 0..<10 {
      let direct = "203.0.113.\(index)"
      let identity = await service.identity(peerAddress: direct, forwardedFor: nil)
      _ = await service.recordFailure(
        identity, path: "/api/v1/ping", reason: "bad", peerAddress: direct)
    }

    let identity = await service.identity(peerAddress: "203.0.113.5", forwardedFor: nil)
    #expect(identity == .address("203.0.113.5"))
  }

  @Test("An untrusted peer cannot be tripped, however its failures are reported")
  func untrustedPeerIsNeverTripped() async {
    // The guard this pins is `isTrustedProxy`, and it is NOT redundant with `peer !=
    // address` even though it looks it. Through `identity()` an untrusted peer always
    // resolves to itself, so the two guards coincide — which is why a test driven only
    // through that path cannot tell them apart, and the first draft of this file could not.
    //
    // `recordFailure` is public and takes the peer and the identity separately. A caller
    // that pairs an untrusted peer with some other address would, without the trust check,
    // trip that peer and stop attributing a client that never claimed anything: the
    // "one bad actor took a real client offline" failure this whole file is shaped around.
    let service = service(churnLimit: 3, clock: ManualClock())
    let untrusted = "203.0.113.5"

    for index in 0..<10 {
      _ = await service.recordFailure(
        .address("198.51.100.\(index)"), path: "/api/v1/ping", reason: "bad",
        peerAddress: untrusted)
    }

    #expect(
      await service.identity(peerAddress: untrusted, forwardedFor: nil) == .address(untrusted),
      "an untrusted peer must never be tripped")
  }

  @Test("The ceiling lapses, so a tripped proxy recovers on its own")
  func trippingExpires() async {
    // Without this a single burst disables attribution for the life of the process, and the
    // operator's only recovery is a restart.
    let clock = ManualClock()
    let service = service(churnLimit: 3, clock: clock)
    for index in 0..<6 { _ = await attempt(service, claiming: "198.51.100.\(index)") }
    #expect(
      await service.identity(peerAddress: loopback, forwardedFor: "198.51.100.7")
        == .unresolved)

    clock.advance(by: 301)

    #expect(
      await service.identity(peerAddress: loopback, forwardedFor: "198.51.100.7")
        == .address("198.51.100.7"),
      "the window must lapse")
  }

  // MARK: - The default that made the above reachable for free

  @Test("Trusting the local network is OFF by default")
  func localNetworkIsNotTrustedByDefault() {
    // This shipped `true` while `docs/AUTH.md` said private ranges are not allowlisted by
    // default and `AccessControl.trustLocalNetwork`'s own comment said "a LAN is not
    // automatically friendly". On, it allowlists 10/8, 172.16/12 and 192.168/16, and an
    // allowlisted address is never counted and never blocked — an unlimited password budget
    // for anything that has joined the Wi-Fi, and, via a forged header, for anything that
    // can merely name one. Asserted rather than left to the registry, because a default is
    // one character and nothing else fails when it moves.
    #expect(Settings.trustLocalNetwork.defaultValue == false)
  }
}
