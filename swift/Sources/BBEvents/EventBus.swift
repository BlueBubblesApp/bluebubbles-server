//  EventBus
//  Fan-out to sinks, with every sink independently optional.
//
//  There is no primary delivery route. A socket-only install, a webhook-only install, and a
//  full FCM install are all first-class, and none of them logs a warning about the sinks it
//  does not have. A missing Firebase config is a configuration, not a defect.
//
//  The property that matters most operationally: one sink failing must not affect another.
//  A webhook endpoint that hangs cannot delay socket delivery, and an FCM outage cannot stop
//  webhooks. Each sink has its own delivery lane (a serial queue with a per-event timeout)
//  so `emit` returns once the event is queued, order is kept per sink, and a slow sink only
//  ever delays itself.
//
//  See `docs/EVENTS.md`.

import BBCore
import Foundation
import Logging

public struct SinkID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }

  public static let socket = SinkID("socket")
  public static let push = SinkID("push")
  public static let webhook = SinkID("webhook")
  public static let ntfy = SinkID("ntfy")
}

/// Which routing rules a sink is subject to.
///
/// Declared by the sink rather than inferred from its `SinkID`. `SinkID` wraps a string, so
/// a switch over it needs a `default`, and a sink whose id is not a known constant would
/// silently inherit whichever rules the default names: including whether typing indicators
/// reach it. This enum can be switched exhaustively.
public enum SinkRouting: Sendable, Equatable {
  case socket
  case push
  case webhook
}

public protocol EventSink: Sendable {
  /// Which of the three routing rules this sink follows. Deliberately without a default: a
  /// sink says which rules it follows rather than inheriting some silently.
  var routing: SinkRouting { get }

  var id: SinkID { get }
  /// Which payload this sink wants. The socket takes `.full`; everything else takes the
  /// trimmed `.notification` variant.
  var projection: PayloadProjection { get }
  /// Consulted per event, so a webhook subscribed to two event types is not woken for the
  /// other twenty.
  func accepts(_ event: ServerEvent) async -> Bool
  func deliver(_ event: ServerEvent) async throws
}

/// Third-party and non-built-in sinks implement this instead.
///
/// It is the same protocol. That is the point: `WebhookSink` and `NtfySink` are written
/// against it rather than being special-cased, so if the extension surface cannot express
/// the built-ins, it is not good enough. See `docs/EVENTS.md`; the extension seam.
public protocol CustomEventSink: EventSink {}

// MARK: - The bus

public actor EventBus {

  private var sinks: [SinkID: any EventSink] = [:]
  /// One per registered sink. The continuation feeds it; the task drains it in order.
  private struct Lane {
    let routing: SinkRouting
    let continuation: AsyncStream<ServerEvent>.Continuation
    let task: Task<Void, Never>
  }
  private var lanes: [SinkID: Lane] = [:]
  /// Sinks that are currently losing events, and how many each has lost this episode.
  /// Cleared when the sink delivers again, which is what closes the report.
  private var droppedEvents: [SinkID: Int] = [:]
  /// Events queued on a lane and not yet delivered (or timed out). Zero means quiet.
  private var inFlight = 0
  private var settleWaiters: [CheckedContinuation<Void, Never>] = []
  private let logger: Logger
  /// Spacing for events that declare a `minimumInterval`.
  ///
  /// COALESCING, not dropping. Keeping the first event in each window and discarding the
  /// rest is right for a counter and wrong for state: a FindMy batch covering forty devices
  /// would deliver one position and lose thirty-nine, and the survivor would be the oldest.
  /// Keyed per device, the newest position for each is delivered, spaced.
  private var limiter: CoalescingRateLimiter<String, ServerEvent>?
  /// A sink that hangs must not hold a delivery task forever.
  private let deliveryTimeout: Duration

  /// No alert centre here, deliberately. Delivery failures are LOGGED, never raised: one
  /// failed webhook POST is not worth interrupting anyone over, and the sink itself raises
  /// once a failure becomes persistent: it is the only thing that knows the difference.
  public init(
    logger: Logger = Logger(label: "bluebubbles.events"),
    deliveryTimeout: Duration = .seconds(30)
  ) {
    self.logger = logger
    self.deliveryTimeout = deliveryTimeout
  }

  /// Registering is how a sink becomes active. A sink with no configuration is simply not
  /// registered: not registered-and-disabled, which is what turns "no Firebase" into a
  /// warning state rather than a valid deployment.
  public func register(_ sink: any EventSink) {
    unregister(sink.id)
    sinks[sink.id] = sink

    // BOUNDED. `AsyncStream.makeStream` defaults to `.unbounded`, which made the header's
    // claim that "a slow sink only ever delays itself" true about latency and false about
    // memory. `fanOut` yields and returns immediately while the lane delivers serially with
    // a 30-second per-event timeout, so a webhook endpoint that accepts connections and
    // never answers absorbs one event every 30 seconds while a backfill or a FindMy burst
    // enqueues thousands, each retaining a full `ServerEvent` payload. Nothing stopped it.
    //
    // Dropping OLDEST rather than newest: for the state-shaped events (typing, a location,
    // a chat's read state) the newest is the only one worth having, and for the rest a
    // client that has fallen this far behind needs to resync rather than to receive a
    // thousand-event backlog in order. Either way the drop is counted and reported, which is
    // the part the operator currently has no way to learn.
    let (stream, continuation) = AsyncStream.makeStream(
      of: ServerEvent.self, bufferingPolicy: .bufferingNewest(Self.laneCapacity))
    let task = Task { [weak self, logger, deliveryTimeout] in
      for await event in stream {
        await Self.deliver(event, to: sink, timeout: deliveryTimeout, logger: logger)
        await self?.completed()
        await self?.noteDelivered(on: sink.id)
      }
    }
    lanes[sink.id] = Lane(routing: sink.routing, continuation: continuation, task: task)
    logger.debug(
      "Event sink registered",
      metadata: [
        "sink": .string(sink.id.rawValue),
        "routing": .string(String(describing: sink.routing)),
        "sinks": .stringConvertible(lanes.count),
      ])
  }

  /// Stops routing to a sink. Anything already queued for it is still delivered: the lane
  /// is finished, not cancelled, so an event accepted before the unregister is not lost.
  public func unregister(_ id: SinkID) {
    sinks.removeValue(forKey: id)
    lanes.removeValue(forKey: id)?.continuation.finish()
  }

  public var activeSinks: [SinkID] { Array(sinks.keys).sorted { $0.rawValue < $1.rawValue } }

  /// Fan out one event.
  ///
  /// Returns once the event is queued on every eligible lane: not when it is delivered.
  /// Delivery latency is a sink's problem, never the caller's; a test that needs to observe
  /// delivery calls `settle()`.
  /// - Parameter now: The instant to rate-limit against. Injectable because the alternative
  ///   is asserting on real elapsed time, and under a loaded test run two back-to-back
  ///   emits can genuinely fall more than the interval apart, which makes the rate-limit
  ///   test fail intermittently for reasons that have nothing to do with the rate limit.
  public func emit(
    _ event: ServerEvent,
    rateLimitKey: String? = nil,
    now: ContinuousClock.Instant = .now
  ) async {
    let routing = EventRouting.policy(for: event.name)

    if let interval = routing.minimumInterval {
      // Keyed per chat or device where one is available, so a busy one cannot starve a
      // quiet one: EXCEPT where the policy says the limit is global, which is how
      // FindMy protects Apple's service rather than this server's delivery.
      let key =
        routing.isRateLimitGlobal
        ? event.name.rawValue
        : "\(event.name.rawValue)|\(rateLimitKey ?? "")"
      await limiter(for: interval).submit(event, for: key, now: now)
      return
    }

    fanOut(event, routing: routing)
  }

  /// Suspends until every queued event has been delivered or has timed out.
  ///
  /// For tests, and for shutdown through `flushPending`. Not for the request path.
  public func settle() async {
    guard inFlight > 0 else { return }
    await withCheckedContinuation { settleWaiters.append($0) }
  }

  /// Built lazily and reused, because it holds the per-key timing state that IS the rate
  /// limit: a new one per call would make every event look like the first.
  private func limiter(
    for interval: Duration
  ) -> CoalescingRateLimiter<String, ServerEvent> {
    if let limiter { return limiter }
    let created = CoalescingRateLimiter<String, ServerEvent>(
      interval: interval,
      capacity: 2_000
    ) { [weak self] _, event in
      guard let self else { return }
      await self.fanOut(event, routing: EventRouting.policy(for: event.name))
    }
    limiter = created
    return created
  }

  /// How many events a lane may hold before the oldest are dropped.
  ///
  /// Sized for a burst, not a backlog: a full chat.db backfill or a FindMy sweep can enqueue
  /// hundreds in a moment, and a healthy sink drains those in well under a second. A sink
  /// that is 512 events behind is not slow, it is not delivering, and holding more of them
  /// only turns a delivery problem into a memory one.
  static let laneCapacity = 512

  /// Records that a sink fell far enough behind to lose events, and says so ONCE per
  /// episode rather than per event.
  ///
  /// A sink that has stopped draining drops everything from then on, so logging per drop
  /// would bury the line that matters under thousands of copies of itself. The count is
  /// carried so the recovery line can say how much was lost.
  private func noteDrop(on id: SinkID) {
    let previous = droppedEvents[id] ?? 0
    droppedEvents[id] = previous + 1
    if previous == 0 {
      logger.warning(
        "A sink is not keeping up; events are being dropped",
        metadata: [
          "sink": .string(id.rawValue),
          "capacity": .stringConvertible(Self.laneCapacity),
        ])
    }
  }

  /// Called when a lane delivers successfully, to close out a drop episode.
  fileprivate func noteDelivered(on id: SinkID) {
    guard let dropped = droppedEvents.removeValue(forKey: id), dropped > 0 else { return }
    logger.warning(
      "A sink is keeping up again; events were lost while it was behind",
      metadata: [
        "sink": .string(id.rawValue),
        "droppedEvents": .stringConvertible(dropped),
      ])
  }

  /// Queues on every eligible lane. The rate limit is applied before this, never inside.
  private func fanOut(_ event: ServerEvent, routing: EventRouting) {
    var queued = 0
    for (id, lane) in lanes where routing.allows(lane.routing) {
      inFlight += 1
      switch lane.continuation.yield(event) {
      case .enqueued:
        queued += 1
      case .dropped:
        // The lane is full: this sink is more than `laneCapacity` events behind. The
        // in-flight count has to come back down or `completed()` never balances.
        inFlight -= 1
        noteDrop(on: id)
      case .terminated:
        inFlight -= 1
      @unknown default:
        inFlight -= 1
      }
    }
    // Zero lanes is the classic "events go nowhere" state (no socket clients, no
    // webhook, no push configured) and is only ever silent without this line.
    logger.debug(
      queued == 0 ? "Event had no sink" : "Event dispatched",
      metadata: [
        "event": .string(event.name.rawValue),
        "lanes": .stringConvertible(queued),
      ])
  }

  private func completed() {
    inFlight -= 1
    guard inFlight == 0 else { return }
    let waiters = settleWaiters
    settleWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  /// One delivery, off the actor: the sink's own work must not hold the bus.
  private static func deliver(
    _ event: ServerEvent, to sink: any EventSink, timeout: Duration, logger: Logger
  ) async {
    guard await sink.accepts(event) else { return }
    let started = ContinuousClock.now
    do {
      try await withTimeout(timeout) {
        try await sink.deliver(event)
      }
      // Trace: each sink already says what it delivered and to whom at debug. This is
      // the bus-level timing, for when a sink is slow rather than failing.
      logger.trace(
        "Sink delivered",
        metadata: [
          "sink": .string(sink.id.rawValue),
          "event": .string(event.name.rawValue),
          "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
        ])
    } catch {
      // Logged, not raised. A single failed webhook POST is not something to interrupt
      // the user about; the sink itself raises an alert once a failure becomes persistent.
      logger.warning(
        "Sink delivery failed",
        metadata: [
          "sink": .string(sink.id.rawValue),
          "event": .string(event.name.rawValue),
          "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
          "error": .string(String(describing: error)),
        ])
    }
  }

  /// Delivers anything a rate limit is currently holding, then waits for the lanes to drain.
  ///
  /// Called on shutdown so a position held for its interval is not simply lost when the
  /// server stops: that value is the newest one there is. Bounded by the per-event
  /// delivery timeout, so a hung webhook cannot hold shutdown open indefinitely.
  public func flushPending() async {
    await limiter?.flushAll()
    await settle()
  }
}

extension EventRouting {
  /// Exhaustive over the routing classes. A sink says which class it is in; nothing
  /// inherits a rule by default.
  fileprivate func allows(_ routing: SinkRouting) -> Bool {
    switch routing {
    case .socket: allowsSocket
    case .push: allowsPush
    case .webhook: allowsWebhooks
    }
  }
}

// MARK: - Timeout
