//  ServerMetrics
//  What the server is doing, sampled every few seconds, rolled up every minute, and kept for
//  thirty days.
//
//  The numbers already existed and nothing read them: the HTTP layer counted every request
//  into a `RequestMetrics` nobody held, the socket server knew how many clients it had, FCM
//  reported what it delivered into a log line. This holds them in one place, derives the
//  per-minute series Home draws, and writes each finished minute to `MetricsStore` so the
//  history survives a restart.
//
//  **It keeps time on the SERVER.** A value that moves on the clock (memory, CPU, how many
//  clients are connected right now) is the server's to announce, which is the rule in
//  `Sources/BlueBubblesApp/CLAUDE.md`: the app follows `snapshots()` and never runs a timer
//  of its own. The tick is a few seconds because that is how fresh a dashboard needs to be,
//  and it does almost nothing: a handful of actor hops and one `getrusage`.
//
//  **Counts only.** No address, path, message or name reaches a metric or the store; the
//  busiest ROUTES are templates (`/api/v1/chat/:guid`), which `RequestMetrics` already keys
//  by for exactly this reason.

import BBAppStore
import BBCore
import BBEvents
import BBHTTPAPI
import BBPrivateAPIContract
import BBPushKit
import Darwin
import Foundation
import Logging

import struct os.OSAllocatedUnfairLock

public actor ServerMetrics {

  /// Where each live number comes from. Closures, so a test can drive every one of them and
  /// the composition root is the one place that knows the real sources.
  public struct Sources: Sendable {
    public var socketClients: @Sendable () async -> Int
    public var socketEventsSent: @Sendable () async -> Int64
    public var lastClientActivity: @Sendable () -> Date?
    public var requests: @Sendable () async -> [String: RequestMetrics.Snapshot]
    /// Bundle identifiers of the connected Private API helpers; empty when there is no
    /// runtime or nothing is connected.
    public var helpers: @Sendable () async -> Set<String>
    public var memoryBytes: @Sendable () -> UInt64?
    /// CPU time this process has used, user plus system, in seconds.
    public var cpuSeconds: @Sendable () -> Double?

    public init(
      socketClients: @escaping @Sendable () async -> Int = { 0 },
      socketEventsSent: @escaping @Sendable () async -> Int64 = { 0 },
      lastClientActivity: @escaping @Sendable () -> Date? = { nil },
      requests: @escaping @Sendable () async -> [String: RequestMetrics.Snapshot] = { [:] },
      helpers: @escaping @Sendable () async -> Set<String> = { [] },
      memoryBytes: @escaping @Sendable () -> UInt64? = { MemoryFootprint.current() },
      cpuSeconds: @escaping @Sendable () -> Double? = { ServerMetrics.processCPUSeconds() }
    ) {
      self.socketClients = socketClients
      self.socketEventsSent = socketEventsSent
      self.lastClientActivity = lastClientActivity
      self.requests = requests
      self.helpers = helpers
      self.memoryBytes = memoryBytes
      self.cpuSeconds = cpuSeconds
    }
  }

  /// A route template and how often it was asked for.
  public struct RouteCount: Sendable, Equatable {
    public let template: String
    public let requests: Int
    public let errors: Int
  }

  /// One finished minute, for the last-hour sparklines.
  public struct Minute: Sendable, Equatable, Identifiable {
    public let start: Date
    public let values: [MetricKey: Double]
    public var id: Date { start }

    public func value(_ key: MetricKey) -> Double { values[key] ?? 0 }
  }

  /// Everything Home shows about the running server, at one moment.
  public struct Snapshot: Sendable, Equatable {
    public let startedAt: Date
    public let at: Date
    public let memoryBytes: UInt64?
    /// Over the last sample interval, as a share of one core.
    public let cpuPercent: Double?
    public let socketClients: Int
    public let lastClientActivity: Date?
    /// Since this server started.
    public let requests: Int
    public let requestErrors: Int
    public let averageLatencyMilliseconds: Double?
    /// Busiest first; at most five.
    public let busiestRoutes: [RouteCount]
    /// Since start, by event name.
    public let events: [String: Int]
    public let socketEventsSent: Int64
    public let pushDelivered: Int
    public let pushFailed: Int
    public let pushExpired: Int
    public let isMessagesHelperConnected: Bool
    public let isFaceTimeHelperConnected: Bool
    /// The last hour, oldest first, one per finished minute.
    public let recent: [Minute]

    public var uptime: TimeInterval { at.timeIntervalSince(startedAt) }
    public var eventsDispatched: Int { events.values.reduce(0, +) }
    /// `new-message` events since start. What the message-flow chart re-reads on.
    public var newMessages: Int { events[EventName.newMessage.rawValue] ?? 0 }
  }

  /// How often the live numbers are read and a snapshot published.
  public static let sampleInterval: Duration = .seconds(5)
  /// How many finished minutes the in-memory ring keeps.
  static let recentMinutes = 60

  // MARK: - State

  /// Counted from other isolation domains, synchronously: the event bus calls in on its own
  /// actor and must not wait for this one.
  private struct Counters: Sendable {
    var events: [String: Int] = [:]
    var pushDelivered = 0
    var pushFailed = 0
    var pushExpired = 0
  }
  private nonisolated let counters = OSAllocatedUnfairLock(initialState: Counters())

  /// The cumulative totals at the start of the current minute, so the minute's value is a
  /// difference rather than a second set of counters to keep in step.
  struct Baseline {
    var start: Date
    var requests = 0
    var errors = 0
    var duration: Duration = .zero
    var events = 0
    var newMessages = 0
    var pushDelivered = 0
    var pushFailed = 0
    var cpuSeconds: Double?
    var maximumSocketClients = 0
  }

  private let store: MetricsStore?
  private let clock: any BBClock
  private let logger: Logger
  private var sources = Sources()
  private var startedAt: Date
  private var baseline: Baseline
  private var recent: [Minute] = []
  private var lastSample: (at: Date, cpuSeconds: Double?)?
  private var current: Snapshot?
  private var openSpans: [AvailabilitySubject: Int64] = [:]
  private let ticker = OwnedTask()
  private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

  public init(
    store: MetricsStore?, clock: any BBClock = SystemClock(),
    logger: Logger = Logger(label: "bluebubbles.metrics")
  ) {
    self.store = store
    self.clock = clock
    self.logger = logger
    let now = clock.now
    self.startedAt = now
    self.baseline = Baseline(start: Self.minute(containing: now))
  }

  // MARK: - Lifecycle

  /// Starts sampling. Called once per server start, before the services come up, so the
  /// first requests and events are counted.
  public func start(sources: Sources, ticking: Bool = true) async {
    self.sources = sources
    let now = clock.now
    startedAt = now
    baseline = Baseline(start: Self.minute(containing: now), cpuSeconds: sources.cpuSeconds())
    recent = []
    lastSample = nil
    counters.withLock { $0 = Counters() }

    // A span a previous process left open ended no later than the last minute it flushed:
    // that is the last moment anything can vouch for.
    do {
      let lastAlive = try await store?.lastRecordedMinute().map { $0.addingTimeInterval(60) }
      try await store?.closeAbandoned(at: lastAlive ?? now)
    } catch {
      logger.warning(
        "Could not close availability left open by the previous run",
        metadata: ["error": .string(String(describing: error))])
    }
    await openSpan(.server, at: now)

    await tick()
    guard ticking else { return }
    ticker.runPeriodically(every: Self.sampleInterval, after: Self.sampleInterval) {
      [weak self] in
      await self?.tick()
    }
  }

  /// Stops sampling, flushes the minute in progress and closes every open span.
  public func stop() async {
    ticker.cancel()
    let now = clock.now
    await flush(minuteEndingAt: now)
    for subject in Array(openSpans.keys) {
      await closeSpan(subject, at: now)
    }
    for continuation in subscribers.values { continuation.finish() }
    subscribers = [:]
    current = nil
  }

  // MARK: - Counting

  /// Installed as the event bus's dispatch observer. Synchronous and lock-guarded, because
  /// the bus calls it on its own actor.
  public nonisolated func noteDispatched(_ name: EventName) {
    counters.withLock { $0.events[name.rawValue, default: 0] += 1 }
  }

  /// Handed to the push service, which reports every send.
  public nonisolated func notePush(_ report: DeliveryReport) {
    counters.withLock {
      $0.pushDelivered += report.deliveredCount
      $0.pushFailed += report.failureCount
      $0.pushExpired += report.expiredTokens.count
    }
  }

  // MARK: - Reading

  /// The most recent snapshot, or nil before the first sample and after `stop`.
  public var snapshot: Snapshot? { current }

  /// The snapshot, again after every sample. The newest is kept for a slow consumer. A
  /// consumer that needs the value before the next sample reads `snapshot`.
  public func snapshots() -> AsyncStream<Snapshot> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    subscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeSubscriber(id) }
    }
    return stream
  }

  private func removeSubscriber(_ id: UUID) {
    subscribers[id] = nil
  }

  /// A stored series, for a window longer than the in-memory hour.
  public func history(_ metric: MetricKey, since start: Date) async throws -> [MetricPoint] {
    try await store?.series(metric, since: start) ?? []
  }

  /// When the server and its helpers were up, for the uptime timeline.
  public func availability(since start: Date) async throws -> [AvailabilitySpan] {
    try await store?.spans(since: start) ?? []
  }

  // MARK: - Sampling

  /// One sample. Internal so a test can drive it without waiting on the ticker.
  func tick() async {
    let now = clock.now
    let clients = await sources.socketClients()
    let sent = await sources.socketEventsSent()
    let routes = await sources.requests()
    let helpers = await sources.helpers()
    let cpu = sources.cpuSeconds()

    // A minute boundary passed since the last sample: finish it before this sample counts
    // toward the next one. More than one boundary (the Mac slept) finishes only the minute
    // that was in progress; the minutes it slept through are a gap, not zeros.
    if Self.minute(containing: now) > baseline.start {
      await flush(minuteEndingAt: now)
    }
    baseline.maximumSocketClients = max(baseline.maximumSocketClients, clients)

    await follow(helpers: helpers, at: now)

    let totals = Self.requestTotals(routes)
    let counted = counters.withLock { $0 }
    let cpuPercent: Double? = {
      guard let last = lastSample, let previous = last.cpuSeconds, let cpu else { return nil }
      let elapsed = now.timeIntervalSince(last.at)
      guard elapsed > 0 else { return nil }
      return max(0, (cpu - previous) / elapsed * 100)
    }()
    lastSample = (now, cpu)

    let snapshot = Snapshot(
      startedAt: startedAt,
      at: now,
      memoryBytes: sources.memoryBytes(),
      cpuPercent: cpuPercent,
      socketClients: clients,
      lastClientActivity: sources.lastClientActivity(),
      requests: totals.requests,
      requestErrors: totals.errors,
      averageLatencyMilliseconds: totals.requests > 0
        ? Self.milliseconds(totals.duration) / Double(totals.requests) : nil,
      busiestRoutes: Self.busiest(routes, limit: 5),
      events: counted.events,
      socketEventsSent: sent,
      pushDelivered: counted.pushDelivered,
      pushFailed: counted.pushFailed,
      pushExpired: counted.pushExpired,
      isMessagesHelperConnected: helpers.contains(HelperHost.messages),
      isFaceTimeHelperConnected: helpers.contains(HelperHost.faceTime),
      recent: recent)
    current = snapshot
    for continuation in subscribers.values { continuation.yield(snapshot) }
  }

  /// Closes the minute in progress: its values into the ring and the store, and a new
  /// baseline from here.
  private func flush(minuteEndingAt now: Date) async {
    let routes = await sources.requests()
    let totals = Self.requestTotals(routes)
    let counted = counters.withLock { $0 }
    let events = counted.events.values.reduce(0, +)
    let newMessages = counted.events[EventName.newMessage.rawValue] ?? 0
    let cpu = sources.cpuSeconds()
    let elapsed = now.timeIntervalSince(baseline.start)

    let minute = Minute(
      start: baseline.start,
      values: Self.minuteValues(
        from: baseline,
        requests: totals.requests, errors: totals.errors, duration: totals.duration,
        events: events, newMessages: newMessages,
        pushDelivered: counted.pushDelivered, pushFailed: counted.pushFailed,
        memoryBytes: sources.memoryBytes(), cpuSeconds: cpu, elapsed: elapsed))

    recent.append(minute)
    if recent.count > Self.recentMinutes { recent.removeFirst(recent.count - Self.recentMinutes) }

    do {
      try await store?.record(minute: minute.start, values: minute.values)
      try await store?.prune(before: now.addingTimeInterval(-MetricsStore.retention))
    } catch {
      // Logged and not raised: a dashboard missing a minute is not worth interrupting
      // anyone over, and the next flush tries again.
      logger.warning(
        "Could not record a minute of server metrics",
        metadata: ["error": .string(String(describing: error))])
    }

    baseline = Baseline(
      start: Self.minute(containing: now),
      requests: totals.requests, errors: totals.errors, duration: totals.duration,
      events: events, newMessages: newMessages,
      pushDelivered: counted.pushDelivered, pushFailed: counted.pushFailed,
      cpuSeconds: cpu,
      // The clients connected NOW are connected in the new minute too.
      maximumSocketClients: current?.socketClients ?? 0)
  }

  /// A finished minute's values: differences for the counters, the reading at the end for
  /// memory, and CPU as a share of the time the minute actually covered.
  static func minuteValues(
    from baseline: Baseline,
    requests: Int, errors: Int, duration: Duration,
    events: Int, newMessages: Int, pushDelivered: Int, pushFailed: Int,
    memoryBytes: UInt64?, cpuSeconds: Double?, elapsed: TimeInterval
  ) -> [MetricKey: Double] {
    let requestCount = max(0, requests - baseline.requests)
    var values: [MetricKey: Double] = [
      .requests: Double(requestCount),
      .requestErrors: Double(max(0, errors - baseline.errors)),
      .socketClients: Double(baseline.maximumSocketClients),
      .events: Double(max(0, events - baseline.events)),
      .newMessages: Double(max(0, newMessages - baseline.newMessages)),
      .pushDelivered: Double(max(0, pushDelivered - baseline.pushDelivered)),
      .pushFailed: Double(max(0, pushFailed - baseline.pushFailed)),
    ]
    if requestCount > 0 {
      values[.averageLatencyMilliseconds] =
        milliseconds(duration - baseline.duration) / Double(requestCount)
    }
    if let memoryBytes {
      values[.memoryMegabytes] = Double(memoryBytes) / 1_048_576
    }
    if let cpuSeconds, let previous = baseline.cpuSeconds, elapsed > 0 {
      values[.cpuPercent] = max(0, (cpuSeconds - previous) / elapsed * 100)
    }
    return values
  }

  // MARK: - Availability

  private func follow(helpers: Set<String>, at now: Date) async {
    for (subject, host) in [
      (AvailabilitySubject.messagesHelper, HelperHost.messages),
      (.faceTimeHelper, HelperHost.faceTime),
    ] {
      let isUp = helpers.contains(host)
      let isOpen = openSpans[subject] != nil
      if isUp && !isOpen { await openSpan(subject, at: now) }
      if !isUp && isOpen { await closeSpan(subject, at: now) }
    }
  }

  private func openSpan(_ subject: AvailabilitySubject, at start: Date) async {
    do {
      if let id = try await store?.open(subject, at: start) { openSpans[subject] = id }
    } catch {
      logger.warning(
        "Could not record availability",
        metadata: [
          "series": .string(subject.rawValue), "error": .string(String(describing: error)),
        ])
    }
  }

  private func closeSpan(_ subject: AvailabilitySubject, at end: Date) async {
    guard let id = openSpans.removeValue(forKey: subject) else { return }
    do {
      try await store?.close(span: id, at: end)
    } catch {
      logger.warning(
        "Could not record availability",
        metadata: [
          "series": .string(subject.rawValue), "error": .string(String(describing: error)),
        ])
    }
  }

  // MARK: - Helpers

  static func minute(containing date: Date) -> Date {
    Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
  }

  static func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
  }

  static func requestTotals(
    _ routes: [String: RequestMetrics.Snapshot]
  ) -> (requests: Int, errors: Int, duration: Duration) {
    routes.values.reduce((0, 0, Duration.zero)) {
      ($0.0 + $1.requests, $0.1 + $1.errors, $0.2 + $1.totalDuration)
    }
  }

  static func busiest(_ routes: [String: RequestMetrics.Snapshot], limit: Int) -> [RouteCount] {
    routes
      .map { RouteCount(template: $0.key, requests: $0.value.requests, errors: $0.value.errors) }
      .sorted {
        $0.requests != $1.requests ? $0.requests > $1.requests : $0.template < $1.template
      }
      .prefix(limit)
      .map { $0 }
  }

  /// User plus system CPU time, from `getrusage`.
  public static func processCPUSeconds() -> Double? {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
    func seconds(_ time: timeval) -> Double {
      Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
  }
}
