//  WebhookRetry
//  What a webhook does after a failed delivery, and the queue that does it.
//
//  Without this a failed POST was the end of that event for that endpoint: an endpoint that
//  restarted for thirty seconds lost every message in those thirty seconds, and nothing told
//  its owner which ones. Two decisions shape the fix.
//
//  **Retries run beside the event lane, never in it.** The bus delivers to the webhook sink one
//  event at a time, so a retry that waited inside `deliver` would hold every other endpoint's
//  events behind one endpoint's backoff. The outbox is drained by its own tasks, one per
//  endpoint, and the lane only ever makes a first attempt.
//
//  **An endpoint that is failing gets an ordered outbox, not a scatter of timers.** Once a
//  delivery fails, newer events for that endpoint queue behind it rather than being tried at
//  once. So the endpoint receives events in the order they happened, it is not sent a burst
//  while it is down, and an endpoint that HANGS costs one timeout rather than one per event.
//  When the head of the outbox gets through, the rest follow at once, in order.
//
//  Every attempt at one event carries the same `X-BlueBubbles-Delivery-Id`, and
//  `X-BlueBubbles-Delivery-Attempt` counts them. Headers rather than a body field: the body is
//  `{"type", "data"}` and consumers parse it, and the one thing a retry has to give a receiver
//  (a key to drop a duplicate on, when a response was lost after the work was done) is
//  metadata about the request rather than part of the event.
//
//  The outbox is in memory. A restart discards it, and the service logs how many were
//  waiting.
//
//  See `docs/EVENTS.md`.

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Policy

/// How often, and how patiently, a webhook's failed deliveries are retried.
public struct WebhookRetryPolicy: Sendable, Equatable {

  /// How many times one event may be retried after its first attempt fails. Ten retries
  /// from a 30-second start is about four hours (the wait stops doubling at an hour), which
  /// is as long as an event is worth holding in memory.
  public static let retryRange = 0...10
  /// The wait before the first retry, in seconds.
  public static let initialDelayRange = 5...3600
  /// No wait between attempts is ever longer than this, however many have failed.
  public static let maximumDelaySeconds = 3600

  /// Retries after the first attempt. Zero is no retrying at all.
  public let maxRetries: Int
  /// The wait before the first retry. Each later one doubles it, up to the maximum.
  public let initialDelaySeconds: Int

  /// Clamped into range rather than refused: a stored value from a later version, or one
  /// written by hand, still produces a policy that terminates.
  public init(maxRetries: Int, initialDelaySeconds: Int) {
    self.maxRetries = min(
      max(maxRetries, Self.retryRange.lowerBound), Self.retryRange.upperBound)
    self.initialDelaySeconds = min(
      max(initialDelaySeconds, Self.initialDelayRange.lowerBound),
      Self.initialDelayRange.upperBound)
  }

  /// No retrying: a failed delivery is recorded and the event is gone.
  public static let off = WebhookRetryPolicy(maxRetries: 0, initialDelaySeconds: 30)
  /// Five retries starting at 30 seconds: 30 s, 1, 2, 4 and 8 minutes, so about a quarter
  /// of an hour before an event is given up on. Long enough to ride out a deploy or a
  /// restart of the receiving end.
  public static let standard = WebhookRetryPolicy(maxRetries: 5, initialDelaySeconds: 30)

  public var isEnabled: Bool { maxRetries > 0 }

  /// The wait after `failures` consecutive failed attempts (1 is the first), before jitter.
  public func nominalDelay(afterFailures failures: Int) -> Duration {
    // Capped before shifting so the shift cannot overflow; 2^12 already passes the maximum
    // from the smallest start.
    let exponent = min(max(failures - 1, 0), 12)
    return .seconds(min(initialDelaySeconds << exponent, Self.maximumDelaySeconds))
  }

  /// The wait actually used: the nominal one scaled by 0.8 to 1.2.
  ///
  /// Jittered so that endpoints that failed together (one receiver behind one load balancer,
  /// all of them down for the same deploy) do not all retry in the same instant.
  /// - Parameter jitter: a value in `0..<1`; 0.5 is the nominal delay.
  public func delay(afterFailures failures: Int, jitter: Double) -> Duration {
    nominalDelay(afterFailures: failures) * (0.8 + 0.4 * min(max(jitter, 0), 1))
  }

  /// Whether a failure is worth trying again.
  ///
  /// Yes for what a later attempt can plausibly change: a timeout, a connection that could
  /// not be made or was lost, HTTP 408, 425 and 429, and every 5xx. No for the rest, which
  /// say the request ITSELF was refused (a 400, a 401, a 404, a redirect this webhook does
  /// not follow, a URL that is not one) and would be refused again in exactly the same way.
  /// An error this does not recognise is not retried: it is far more likely to be
  /// deterministic than to clear up on its own.
  public static func isRetryable(_ error: any Error) -> Bool {
    if let post = error as? URLSessionPoster.PostError {
      switch post {
      case .httpStatus(let status): return [408, 425, 429].contains(status) || status >= 500
      case .invalidURL: return false
      }
    }
    if let url = error as? URLError {
      return retryableURLErrors.contains(url.code)
    }
    return false
  }

  private static let retryableURLErrors: Set<URLError.Code> = [
    .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
    .dnsLookupFailed, .notConnectedToInternet, .badServerResponse, .resourceUnavailable,
    .cannotLoadFromNetwork,
  ]

  /// Whether an event is worth delivering late at all.
  ///
  /// A typing indicator is not: by the time a retry could land, the person has stopped or
  /// sent the message, and a stale "is typing" is worse than none. Every other event is a
  /// record of something that happened, which is still true minutes later.
  public static func retries(_ name: EventName) -> Bool {
    name != .typingIndicator
  }
}

// MARK: - Outbox

/// The events waiting for each failing endpoint, oldest first.
///
/// A value type, and pure: every decision takes `now` and the delay as arguments, so the
/// ordering and give-up rules can be asserted without a clock. `WebhookSink` owns one and
/// does the posting.
struct WebhookOutboxes: Sendable {

  /// How many events one endpoint may have waiting. Past this the OLDEST is dropped: an
  /// endpoint this far behind has been down for a while, and the newest events are the ones
  /// its owner is most likely to still want.
  static let capacity = 500

  struct Entry: Sendable {
    let event: ServerEvent
    /// The same on every attempt; see the file header.
    let deliveryID: UUID
    /// Attempts already made. Zero for an event that queued behind a failure and has not
    /// been tried yet.
    var attemptsMade: Int
  }

  struct Outbox: Sendable {
    /// What the outbox was filled for. A webhook whose URL has changed since is not sent
    /// the old address's backlog, for the reason `WebhookDeliveryState.url` exists.
    let url: String
    var entries: [Entry]
    /// Failed attempts in a row, which is what the backoff grows on.
    var failures: Int
    var nextAttemptAt: ContinuousClock.Instant
    /// A task is sending from this outbox; nothing else may start one.
    var isDraining = false
    /// Events dropped for capacity since the outbox opened, so the log says it once.
    var dropped = 0
  }

  enum FailureResult: Equatable {
    /// Back at the head of the outbox, to be tried again.
    case willRetry
    /// Discarded: out of retries, or refused in a way a retry would not change.
    case gaveUp
  }

  private(set) var outboxes: [Int64: Outbox] = [:]

  /// Whether new events for this endpoint queue rather than being sent.
  ///
  /// True from the first failure until the outbox is empty AND nothing is being sent from
  /// it, so an event that arrives while the backlog is draining still lands behind it.
  func isBackingOff(_ id: Int64, url: String) -> Bool {
    outboxes[id]?.url == url
  }

  func waiting(_ id: Int64) -> Int { outboxes[id]?.entries.count ?? 0 }

  func failures(_ id: Int64) -> Int { outboxes[id]?.failures ?? 0 }

  /// When this endpoint's outbox next sends, or nil when nothing is waiting or the next
  /// attempt is already due, which is to say it is sending now or about to.
  func nextAttempt(_ id: Int64, now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
    guard let outbox = outboxes[id], !outbox.entries.isEmpty, outbox.nextAttemptAt > now else {
      return nil
    }
    return outbox.nextAttemptAt
  }

  /// The earliest moment any outbox wants sending from.
  var nextWake: ContinuousClock.Instant? {
    outboxes.values
      .filter { !$0.isDraining && !$0.entries.isEmpty }
      .map(\.nextAttemptAt)
      .min()
  }

  /// Opens an outbox after a first attempt failed, or joins one already open.
  mutating func open(
    with entry: Entry, id: Int64, url: String, delay: Duration, now: ContinuousClock.Instant
  ) {
    if outboxes[id]?.url == url {
      append(entry, id: id)
      return
    }
    outboxes[id] = Outbox(url: url, entries: [entry], failures: 1, nextAttemptAt: now + delay)
  }

  /// Queues an event behind the ones already waiting.
  ///
  /// - Returns: whether this is the first event dropped for capacity since the outbox
  ///   opened, which is when the caller says so.
  @discardableResult
  mutating func append(_ entry: Entry, id: Int64) -> Bool {
    guard var outbox = outboxes[id] else { return false }
    outbox.entries.append(entry)
    var firstDrop = false
    if outbox.entries.count > Self.capacity {
      outbox.entries.removeFirst()
      firstDrop = outbox.dropped == 0
      outbox.dropped += 1
    }
    outboxes[id] = outbox
    return firstDrop
  }

  /// The endpoints whose next attempt is due, each marked as draining so a second task
  /// cannot start on it.
  mutating func takeDue(at now: ContinuousClock.Instant) -> [Int64] {
    let due = outboxes.filter { _, outbox in
      !outbox.isDraining && !outbox.entries.isEmpty && outbox.nextAttemptAt <= now
    }.keys.sorted()
    for id in due { outboxes[id]?.isDraining = true }
    return due
  }

  /// The oldest waiting event, removed while it is being sent.
  ///
  /// Taken off the queue rather than read from it, so a capacity drop while the POST is in
  /// flight can never remove the event being sent; `failed` puts it back.
  mutating func takeHead(_ id: Int64) -> Entry? {
    guard var outbox = outboxes[id], !outbox.entries.isEmpty else { return nil }
    let head = outbox.entries.removeFirst()
    outboxes[id] = outbox
    return head
  }

  /// The endpoint answered: the backoff resets and the next event goes at once.
  mutating func delivered(_ id: Int64, now: ContinuousClock.Instant) {
    outboxes[id]?.failures = 0
    outboxes[id]?.nextAttemptAt = now
  }

  /// An attempt failed. `entry.attemptsMade` already counts it.
  ///
  /// A retryable failure moves the next attempt out by `delay`, whether or not this event
  /// had retries left: the endpoint is still down, and the event behind it would fail the
  /// same way now. A failure that is not retryable leaves the schedule alone, because it was
  /// about this request rather than about the endpoint.
  mutating func failed(
    _ entry: Entry, id: Int64, retryable: Bool, policy: WebhookRetryPolicy,
    delay: Duration, now: ContinuousClock.Instant
  ) -> FailureResult {
    guard var outbox = outboxes[id] else { return .gaveUp }
    var result = FailureResult.gaveUp
    if retryable {
      outbox.failures += 1
      outbox.nextAttemptAt = now + delay
      if entry.attemptsMade <= policy.maxRetries {
        outbox.entries.insert(entry, at: 0)
        result = .willRetry
      }
    }
    outboxes[id] = outbox
    return result
  }

  /// Sending has stopped for now. An outbox with nothing left in it closes, and the endpoint
  /// is sent new events directly again.
  mutating func finishDraining(_ id: Int64) {
    guard var outbox = outboxes[id] else { return }
    if outbox.entries.isEmpty {
      outboxes[id] = nil
    } else {
      outbox.isDraining = false
      outboxes[id] = outbox
    }
  }

  /// Drops one endpoint's outbox. Returns how many events were in it.
  @discardableResult
  mutating func discard(_ id: Int64) -> Int {
    outboxes.removeValue(forKey: id)?.entries.count ?? 0
  }

  /// Drops every outbox. Returns how many events were waiting.
  mutating func discardAll() -> Int {
    let count = outboxes.values.reduce(0) { $0 + $1.entries.count }
    outboxes = [:]
    return count
  }
}
