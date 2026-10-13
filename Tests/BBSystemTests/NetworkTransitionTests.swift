//  NetworkTransitionTests
//  Which sequences of paths count as something happening.
//
//  Two assertions carry this file, and both are about NOT reporting things.
//
//  A path that stays satisfied while the interfaces move — Wi-Fi to Ethernet, a VPN coming up —
//  must not read as "the network came back". Everything is working during one of those, and a
//  consumer that restarted six tunnels on it would be inventing the outage this subsystem
//  exists to prevent.
//
//  And the FIRST observation is never a transition, however satisfied it is. The server has
//  just started and is about to start everything anyway; announcing an arrival at launch would
//  have every consumer act on a change that did not occur.

import Foundation
import Testing

@testable import BBSystem

@Suite("Network transitions")
struct NetworkTransitionTests {

  static func path(
    _ satisfied: Bool, interfaces: [String] = ["en0"], addresses: [String] = ["192.168.1.50"]
  ) -> NetworkPath {
    NetworkPath(isSatisfied: satisfied, interfaces: interfaces, localAddresses: addresses)
  }

  // MARK: - The edge that matters

  @Test("Unsatisfied to satisfied is the retry cue")
  func becameAvailable() {
    let transition = NetworkTransitionDetector.transition(
      from: .unavailable, to: Self.path(true))
    #expect(transition == .becameAvailable(Self.path(true)))
    #expect(transition?.permitsRetry == true)
  }

  @Test("Satisfied to unsatisfied is reported, and is not a retry cue")
  func becameUnavailable() {
    let transition = NetworkTransitionDetector.transition(
      from: Self.path(true), to: .unavailable)
    #expect(transition == .becameUnavailable(.unavailable))
    #expect(transition?.permitsRetry == false)
  }

  // MARK: - The two that must stay quiet

  /// The mistake that would turn a transition nobody noticed into a real outage.
  @Test("A route that moves while staying up is not the network coming back")
  func interfaceMoveIsNotAnArrival() {
    let wifi = Self.path(true, interfaces: ["en0"], addresses: ["192.168.1.50"])
    let ethernet = Self.path(true, interfaces: ["en1"], addresses: ["192.168.1.51"])
    let transition = NetworkTransitionDetector.transition(from: wifi, to: ethernet)

    #expect(transition == .changed(ethernet))
    #expect(transition?.permitsRetry == false, "a move must never permit a retry storm")
  }

  @Test("The first observation is never a transition", arguments: [true, false])
  func firstObservationIsSilent(satisfied: Bool) {
    #expect(NetworkTransitionDetector.transition(from: nil, to: Self.path(satisfied)) == nil)
  }

  @Test("An identical path reports nothing")
  func noChange() {
    #expect(NetworkTransitionDetector.transition(from: Self.path(true), to: Self.path(true)) == nil)
    #expect(NetworkTransitionDetector.transition(from: .unavailable, to: .unavailable) == nil)
  }

  /// These move on their own — a hotspot reporting differently, Low Data Mode toggling — and
  /// nothing acts on them, so they must not wake anybody up.
  @Test("Expensive and constrained changing alone is not a transition")
  func meteringIsNotATransition() {
    let cheap = NetworkPath(isSatisfied: true, interfaces: ["en0"], localAddresses: ["10.0.0.2"])
    let costly = NetworkPath(
      isSatisfied: true, isExpensive: true, isConstrained: true,
      interfaces: ["en0"], localAddresses: ["10.0.0.2"])
    #expect(NetworkTransitionDetector.transition(from: cheap, to: costly) == nil)
  }

  @Test("An address appearing or leaving on the same interface is a change")
  func addressMove() {
    let before = Self.path(true, addresses: ["192.168.1.50"])
    let after = Self.path(true, addresses: ["192.168.1.50", "10.8.0.2"])
    #expect(NetworkTransitionDetector.transition(from: before, to: after) == .changed(after))
  }

  // MARK: - What the HTTP listener will ask

  /// The recorded bug: a path can be perfectly satisfied over Ethernet while the Wi-Fi address
  /// the listener was pinned to has gone.
  @Test("A satisfied path can have lost the address something was pinned to")
  func holdsAddress() {
    let path = Self.path(true, interfaces: ["en1"], addresses: ["192.168.1.51"])
    #expect(path.isSatisfied)
    #expect(path.holds(address: "192.168.1.51"))
    #expect(!path.holds(address: "192.168.1.50"), "the pinned address is gone")
  }

  @Test("Paths are order-independent: the same network compares equal however it is listed")
  func normalised() {
    let a = NetworkPath(isSatisfied: true, interfaces: ["en1", "en0"], localAddresses: ["b", "a"])
    let b = NetworkPath(isSatisfied: true, interfaces: ["en0", "en1"], localAddresses: ["a", "b"])
    #expect(a == b)
    #expect(NetworkTransitionDetector.transition(from: a, to: b) == nil)
  }
}

/// The half of the observer that has a memory, tested without a clock.
///
/// These are the assertions that used to need real sleeps and a loaded machine's cooperation.
/// A sequence of SETTLED paths is what the observer hands this type, so scripting the sequence
/// asserts everything about what gets announced; what remains in the observer is the timing
/// that produces the sequence, and that is one cheap test rather than five slow ones.
@Suite("Network transition coalescer")
struct NetworkTransitionCoalescerTests {

  static func path(_ satisfied: Bool, interfaces: [String] = ["en0"]) -> NetworkPath {
    NetworkPath(
      isSatisfied: satisfied, interfaces: interfaces,
      localAddresses: satisfied ? ["192.168.1.50"] : [])
  }

  @Test("The first settled path announces nothing")
  func firstIsSilent() {
    var coalescer = NetworkTransitionCoalescer()
    #expect(coalescer.settled(Self.path(true)) == nil)
    #expect(coalescer.current == Self.path(true))
  }

  @Test("A drop and a return are announced in order")
  func dropThenReturn() {
    var coalescer = NetworkTransitionCoalescer()
    _ = coalescer.settled(Self.path(true))
    #expect(coalescer.settled(Self.path(false))?.permitsRetry == false)
    #expect(coalescer.settled(Self.path(true))?.permitsRetry == true)
  }

  /// The reason it compares against the last PUBLISHED path. A connection that blipped and
  /// recovered inside one window settled back where it started, and nothing happened.
  @Test("A settled path identical to the last published announces nothing")
  func flapIsSilent() {
    var coalescer = NetworkTransitionCoalescer()
    _ = coalescer.settled(Self.path(true))
    #expect(coalescer.settled(Self.path(true)) == nil)
  }

  @Test("A route that moves while staying up never permits a retry")
  func moveIsNotAnArrival() {
    var coalescer = NetworkTransitionCoalescer()
    _ = coalescer.settled(Self.path(true, interfaces: ["en0"]))
    let transition = coalescer.settled(Self.path(true, interfaces: ["en1"]))
    #expect(transition?.permitsRetry == false)
    if case .changed = transition {
    } else {
      Issue.record("expected a move, got \(String(describing: transition))")
    }
  }

  /// Seeded from a known state, which is what a restarted observer does rather than forgetting
  /// what it had published.
  @Test("A seeded coalescer does not re-announce the state it was seeded with")
  func seeded() {
    var coalescer = NetworkTransitionCoalescer(published: Self.path(true))
    #expect(coalescer.settled(Self.path(true)) == nil)
    #expect(coalescer.settled(Self.path(false))?.permitsRetry == false)
  }
}
