//  NetworkPathObserver
//  Follows the system's network path and publishes what changed.
//
//  `NWPathMonitor` rather than a timer. The kernel already knows when an interface appears or
//  a route moves, and it will say so; asking it repeatedly is both more work and less accurate
//  than being told. It is dispatch-queue based and needs no run loop, so this behaves the same
//  in the headless CLI as it does inside the app — which `NSWorkspace` notifications would not.
//
//  ## It debounces, and that is the point rather than a refinement
//
//  Waking a Mac does not produce one path change. It produces a burst: loopback, then Wi-Fi
//  associating, then a DHCP lease, then a VPN re-establishing, each its own callback over
//  several seconds. Emitting all of them would have every consumer react repeatedly to one
//  event, and the FIRST of them is the least useful — it is the moment the system believes a
//  route exists, which is before DNS resolves and before anything would actually work.
//
//  So updates are collected and evaluated once the burst stops. What is published is the state
//  after things settled, compared against the last state published, which is the comparison a
//  consumer actually wants.
//
//  ## It reports, it does not act
//
//  Nothing here restarts anything. The decision about what a transition permits belongs to
//  whoever is broken; see `docs/NETWORK_AWARENESS.md` §4. Keeping that out of here is what
//  lets this be switched on and watched for a while before anything depends on it.

import BBCore
import Foundation
import Logging
import Network

public actor NetworkPathObserver {

  /// How long the path must be quiet before a change is believed.
  ///
  /// Two seconds, as a starting point rather than a measurement: long enough to swallow the
  /// wake burst, short enough that a real reconnection is not noticeably delayed. The log this
  /// observer writes is what calibrates it — see the ordering note in
  /// `docs/NETWORK_AWARENESS.md` §9.
  public static let defaultDebounce = Duration.seconds(2)

  private let debounce: Duration
  private let logger: Logger
  /// Where paths come FROM. Injected so a test can write a sequence by hand: `NWPath` cannot
  /// be constructed, so an observer that read the monitor directly could only be tested by
  /// changing the network of the machine running the suite.
  private let source: @Sendable () -> AsyncStream<NetworkPath>

  /// What a settled path means, and the memory of the last one published.
  ///
  /// A separate type because it is the half worth testing: this actor's own job is timing,
  /// and `NetworkTransitionCoalescerTests` asserts the rest without a clock.
  private var coalescer: NetworkTransitionCoalescer
  private var pump: Task<Void, Never>?
  private var continuations: [UUID: AsyncStream<NetworkTransition>.Continuation] = [:]

  /// - Parameter startingFrom: the path to treat as already published, so the next settled
  ///   observation is compared against it rather than being the first.
  ///
  ///   The first observation is never a transition — there is nothing to have changed from —
  ///   and `stop()` keeps the coalescer for the same reason. Establishing a baseline by
  ///   FEEDING one and waiting is the alternative, and it is not equivalent: the wait has to
  ///   be a wall-clock sleep, and a sleep does not guarantee the pump was scheduled to consume
  ///   it. When it is not, the baseline and everything after it land in one debounce window,
  ///   the whole lot evaluates as the first observation, and nothing is published at all. That
  ///   was a real intermittent failure in `NetworkPathObserverTests` on a loaded machine, and
  ///   this is what a caller needs to state a baseline rather than race for one.
  public init(
    debounce: Duration = NetworkPathObserver.defaultDebounce,
    logger: Logger = Logger(label: "bluebubbles.network"),
    startingFrom: NetworkPath? = nil,
    source: @escaping @Sendable () -> AsyncStream<NetworkPath>
  ) {
    self.debounce = debounce
    self.logger = logger
    self.coalescer = NetworkTransitionCoalescer(published: startingFrom)
    self.source = source
  }

  /// The real one, over `NWPathMonitor`.
  public init(
    debounce: Duration = NetworkPathObserver.defaultDebounce,
    logger: Logger = Logger(label: "bluebubbles.network")
  ) {
    self.init(debounce: debounce, logger: logger, source: { Self.systemPaths() })
  }

  /// Transitions, from now on. Never replays: a subscriber joining later is told what changes
  /// after it joined, which is all a recovery path can act on anyway.
  public func transitions() -> AsyncStream<NetworkTransition> {
    let id = UUID()
    return AsyncStream { continuation in
      continuations[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeSubscriber(id) }
      }
    }
  }

  public func start() {
    guard pump == nil else { return }
    let source = self.source
    let debounce = self.debounce
    pump = Task { [weak self] in
      // One settle task at a time. A new observation cancels the pending evaluation and
      // restarts the window, which is what collapses a burst into its final state rather
      // than into its first.
      var settle: Task<Void, Never>?
      for await path in source() {
        settle?.cancel()
        settle = Task { [weak self] in
          try? await Task.sleep(for: debounce)
          guard !Task.isCancelled else { return }
          await self?.evaluate(path)
        }
      }
      settle?.cancel()
    }
  }

  public func stop() {
    pump?.cancel()
    pump = nil
    for continuation in continuations.values { continuation.finish() }
    continuations.removeAll()
    // Deliberately NOT resetting the coalescer: a restarted observer that forgot the last
    // path would report the next observation as a transition from nothing, which is the same
    // false "the network arrived" the first-observation rule exists to prevent.
  }

  // MARK: - Internals

  private func removeSubscriber(_ id: UUID) { continuations[id] = nil }

  /// How many settled evaluations have run, transition or not.
  ///
  /// Internal, and it exists so a test can wait for the debounce to have actually FIRED rather
  /// than sleeping a margin and assuming. A margin is a guess about scheduling, and on a
  /// saturated machine it is the wrong guess: see the note on `init(debounce:logger:startingFrom:source:)`.
  private(set) var settledEvaluations = 0

  private func evaluate(_ path: NetworkPath) {
    settledEvaluations += 1
    guard let transition = coalescer.settled(path) else { return }

    // `debug`, not `info`: this is one line per settled network change, which is per unit of
    // work rather than a state transition somebody's support log needs by default.
    //
    // Interface NAMES and a COUNT, never the addresses themselves. `addressCount` is spelled
    // as an aggregate deliberately: `LogRedactionPolicyTests` treats an address-shaped key as
    // carrying an address unless the name says it is a number, and it is right to — the key
    // is what a reader of the log believes the value to be.
    logger.debug(
      "Network path changed",
      metadata: [
        "transition": .string(transition.name),
        "satisfied": .stringConvertible(path.isSatisfied),
        "interfaces": .string(path.interfaces.joined(separator: ",")),
        "addressCount": .stringConvertible(path.localAddresses.count),
      ])

    for continuation in continuations.values { continuation.yield(transition) }
  }

  /// Bridges `NWPathMonitor` into a stream of values.
  ///
  /// The addresses are read here, at the moment the path changes, rather than by the consumer
  /// later: they move WITH the path, and a consumer reading them afterwards would be asking a
  /// different instant's question.
  private static func systemPaths() -> AsyncStream<NetworkPath> {
    AsyncStream { continuation in
      let monitor = NWPathMonitor()
      monitor.pathUpdateHandler = { path in
        continuation.yield(
          NetworkPath(
            isSatisfied: path.status == .satisfied,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            interfaces: path.availableInterfaces.map(\.name),
            localAddresses: SystemInfo.interfaces(.ipv4).map(\.address)
              + SystemInfo.interfaces(.ipv6).map(\.address)
          ))
      }
      continuation.onTermination = { _ in monitor.cancel() }
      monitor.start(queue: DispatchQueue(label: "bluebubbles.network.path"))
    }
  }
}

extension NetworkTransition {
  /// For a log line. Not a wire value and not shown to anyone.
  var name: String {
    switch self {
    case .becameAvailable: "became_available"
    case .becameUnavailable: "became_unavailable"
    case .changed: "changed"
    }
  }
}
