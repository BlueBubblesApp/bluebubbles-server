//  NetworkPath
//  What the system's network looks like at one instant, and what changed between two of them.
//
//  A VALUE, deliberately, with no reference to `NWPath` or anything else from
//  Network.framework. That is what lets the decision layer below be tested by writing paths
//  out by hand: `NWPath` cannot be constructed, so a detector that took one could only be
//  tested on a machine whose network was in the state the test needed.
//
//  `localAddresses` is here rather than derived later because the two halves answer different
//  questions and only one of them comes from the path monitor. A tunnel wants to know whether
//  the internet is reachable; the HTTP listener wants to know whether the specific address it
//  is pinned to still exists on this Mac. `NWPath` answers the first and knows nothing about
//  the second: it reports interfaces, not addresses.

import Foundation

public struct NetworkPath: Sendable, Equatable {

  /// The system believes a route exists.
  ///
  /// **Necessary and not sufficient**, which is the trap this whole subsystem is built around.
  /// On wake, and while associating with Wi-Fi, this becomes true BEFORE DHCP has finished and
  /// before DNS resolves. Anything that acts on it must tolerate the attempt failing.
  public let isSatisfied: Bool

  /// Cellular, a personal hotspot, or otherwise metered.
  public let isExpensive: Bool

  /// Low Data Mode.
  public let isConstrained: Bool

  /// Interface names, sorted: `en0`, `utun3`. From the path monitor.
  public let interfaces: [String]

  /// This Mac's own non-loopback addresses, sorted. From `SystemInfo.interfaces(_:)`, because
  /// the path monitor does not report addresses at all.
  public let localAddresses: [String]

  public init(
    isSatisfied: Bool,
    isExpensive: Bool = false,
    isConstrained: Bool = false,
    interfaces: [String] = [],
    localAddresses: [String] = []
  ) {
    self.isSatisfied = isSatisfied
    self.isExpensive = isExpensive
    self.isConstrained = isConstrained
    self.interfaces = interfaces.sorted()
    self.localAddresses = localAddresses.sorted()
  }

  /// Nothing at all: no route, no interfaces, no addresses. The state a sleeping Mac is in.
  public static let unavailable = NetworkPath(isSatisfied: false)

  /// Whether this Mac still holds `address`.
  ///
  /// What the HTTP listener's pinned `bind_address` needs, and the reason `localAddresses` is
  /// carried: a path can be perfectly satisfied over Ethernet while the Wi-Fi address the
  /// listener was pinned to has gone.
  public func holds(address: String) -> Bool {
    localAddresses.contains(address)
  }
}

/// What changed between two paths.
///
/// Named edges rather than a pair of paths, because the consumers ask different questions and
/// the names are where the answers are decided once. A consumer switching on this cannot
/// accidentally treat "the route changed" as "the network came back".
public enum NetworkTransition: Sendable, Equatable {

  /// Unsatisfied to satisfied. **The one that matters**: it is the moment a service that gave
  /// up has a reason to try again.
  case becameAvailable(NetworkPath)

  /// Satisfied to unsatisfied. Worth knowing and worth acting on carefully: the right response
  /// is usually to record it, not to tear anything down, because whatever broke will report
  /// its own failure and the network may be back before a teardown finishes.
  case becameUnavailable(NetworkPath)

  /// Satisfied throughout, but the interfaces or addresses moved: Wi-Fi to Ethernet, a VPN up
  /// or down, a new DHCP lease.
  ///
  /// Deliberately DISTINCT from `becameAvailable`, and the distinction is the difference
  /// between a working server and an outage: everything is fine during one of these, so a
  /// consumer that restarted six tunnels on it would be inventing the problem it was written
  /// to prevent.
  case changed(NetworkPath)

  /// The path as of this transition.
  public var path: NetworkPath {
    switch self {
    case .becameAvailable(let path), .becameUnavailable(let path), .changed(let path): path
    }
  }

  /// Whether this is a service's cue to retry something it gave up on.
  ///
  /// Only `becameAvailable`. See the note on `changed`.
  public var permitsRetry: Bool {
    if case .becameAvailable = self { return true }
    return false
  }
}

/// Decides what, if anything, happened between two observations.
///
/// PURE, and separate from the observer for the reason the app's rules give for keeping policy
/// off a view: `NWPathMonitor` cannot be driven from a test, so a detector fused to it could
/// only be exercised by changing the network of the machine running the suite. Here a test
/// writes the sequence out.
public enum NetworkTransitionDetector {

  /// `nil` when nothing worth telling anyone about changed.
  ///
  /// `previous` is nil on the first observation. That first path is NOT reported as
  /// `becameAvailable` even when it is satisfied: the server has just started, everything is
  /// about to be started anyway, and announcing "the network arrived" at launch would have
  /// every consumer act on a transition that did not happen.
  public static func transition(from previous: NetworkPath?, to current: NetworkPath)
    -> NetworkTransition?
  {
    guard let previous else { return nil }
    if previous.isSatisfied == current.isSatisfied {
      guard previous.isSatisfied else { return nil }
      // Both satisfied: only a move in the interfaces or the addresses is worth a word.
      // `isExpensive` and `isConstrained` deliberately do not count — they change on their
      // own (a hotspot reporting differently) and nothing here acts on them.
      guard
        previous.interfaces != current.interfaces
          || previous.localAddresses != current.localAddresses
      else { return nil }
      return .changed(current)
    }
    return current.isSatisfied ? .becameAvailable(current) : .becameUnavailable(current)
  }
}

/// Holds the last path published and decides what a newly settled one means.
///
/// Split out of `NetworkPathObserver` so the part with a MEMORY is testable without a clock.
/// The observer's remaining job is timing — collapse a burst, then hand the settled path to
/// this — and timing is the part a test cannot assert cheaply or reliably. What a sequence of
/// settled paths means is the part worth asserting, and it is all here.
///
/// It compares against the last path PUBLISHED, never the last one seen. A connection that
/// drops and recovers inside one debounce window changed nothing, and comparing against the
/// most recent observation would report two transitions for it.
public struct NetworkTransitionCoalescer: Sendable {

  private var published: NetworkPath?

  public init(published: NetworkPath? = nil) {
    self.published = published
  }

  /// The last path published, for a caller that wants to know what is believed to be current.
  public var current: NetworkPath? { published }

  /// Records a settled path and answers what, if anything, to announce.
  public mutating func settled(_ path: NetworkPath) -> NetworkTransition? {
    defer { published = path }
    return NetworkTransitionDetector.transition(from: published, to: path)
  }
}
