//  WebhookDelivery
//  Whether an endpoint is actually receiving anything, and a way to find out on purpose.
//
//  `WebhookSink` counts consecutive failures and raises an alert on the tenth. On its own
//  that leaves the one question anyone has about a webhook (is it working?) answerable
//  only by waiting for ten events to fail, and the commonest failure of all is a URL with a
//  typo in it that never fires and never says so. A registered endpoint that is silently
//  dead looks exactly like a quiet one.
//
//  Two pieces, and they share a code path deliberately:
//
//    - `WebhookDeliveryTracker` holds the last outcome per target, so a list can show it.
//    - `WebhookDelivery.send` is the encode-and-POST, used by real dispatch AND by the test
//      send. A "test" that exercised its own path would prove that the test works.
//
//  The tracked state carries the URL it was recorded for. Row ids are reused by SQLite after
//  a delete, and a stale outcome shown against a newly registered endpoint would be a
//  confident lie rather than a missing answer.
//
//  See `docs/EVENTS.md` and `.claude/docs/architecture.md`.

import BBSerialization
import Foundation
import Logging

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - State

public struct WebhookDeliveryState: Sendable, Equatable {

  public enum Outcome: Sendable, Equatable {
    case delivered
    /// A short human reason: "HTTP 404", "Could not connect to the server". Never the
    /// raw error dump, which is unreadable in a list row.
    case failed(String)

    public var isFailure: Bool {
      if case .failed = self { return true }
      return false
    }
  }

  public let outcome: Outcome
  public let at: Date
  /// Zero after a success. The same counter the alert threshold uses, so what the row shows
  /// and what the alert fires on can never disagree.
  public let consecutiveFailures: Int
  /// The event that was being delivered. "Failed on new-message" is a more useful sentence
  /// than "failed".
  public let event: String
  /// What this outcome was recorded against; see the file comment on reused row ids.
  public let url: String
  /// Events waiting in this endpoint's retry outbox. Zero when it is not backing off.
  public let waiting: Int
  /// When the outbox next sends, or nil when nothing is waiting or it is sending now.
  public let nextAttemptAt: Date?

  public init(
    outcome: Outcome, at: Date, consecutiveFailures: Int, event: String, url: String,
    waiting: Int = 0, nextAttemptAt: Date? = nil
  ) {
    self.outcome = outcome
    self.at = at
    self.consecutiveFailures = consecutiveFailures
    self.event = event
    self.url = url
    self.waiting = waiting
    self.nextAttemptAt = nextAttemptAt
  }

  /// A short reason for a delivery error.
  ///
  /// Deliberately narrow: a status code, a connection problem, or a fallback. Anything
  /// longer does not fit where this is shown, and the full error is already in the log.
  public static func reason(for error: any Error) -> String {
    if let post = error as? URLSessionPoster.PostError {
      switch post {
      case .httpStatus(let code): return "HTTP \(code)"
      case .invalidURL: return "Not a valid URL"
      }
    }
    if let url = error as? URLError {
      return url.localizedDescription
    }
    return String(describing: error)
  }
}

/// Last-known delivery state per webhook. In memory only: it describes what this process has
/// observed since it started, which is the honest scope: persisting it would mean showing
/// "delivered" for an endpoint that was last reached before a reboot three weeks ago.
public actor WebhookDeliveryTracker {

  private var states: [Int64: WebhookDeliveryState] = [:]
  private var observers: [UUID: AsyncStream<[Int64: WebhookDeliveryState]>.Continuation] = [:]

  public init() {}

  // MARK: Observation

  /// Every change to the table, as the whole table, for a page that shows it.
  ///
  /// The whole map rather than the one row that moved, so a follower holds exactly what
  /// `all()` would return and never has to merge. The page that showed this polled it on a
  /// ten-second sleep (the one timer the app had) because there was nothing to follow.
  /// Same shape as `ToolManager.stream()`.
  public func changes() -> AsyncStream<[Int64: WebhookDeliveryState]> {
    let id = UUID()
    return AsyncStream { continuation in
      observers[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeObserver(id) }
      }
    }
  }

  private func removeObserver(_ id: UUID) { observers[id] = nil }

  private func publish() {
    for continuation in observers.values { continuation.yield(states) }
  }

  /// Records an attempt and returns the consecutive failure count after it.
  ///
  /// The count lives here rather than in the sink so that every path that delivers (real
  /// dispatch and the test send) moves the same counter. A successful test send clearing
  /// the failure streak is correct: the endpoint just answered.
  ///
  /// `waiting` and `nextAttemptAt` describe the endpoint's retry outbox as it stands after
  /// this attempt. A nil `waiting` means the caller does not know (the test send, which posts
  /// outside the sink) and both are carried over from the previous state, so pressing Test
  /// does not make a backlog vanish from the row while it is still waiting.
  @discardableResult
  public func record(
    id: Int64,
    url: String,
    event: String,
    outcome: WebhookDeliveryState.Outcome,
    at: Date = Date(),
    waiting: Int? = nil,
    nextAttemptAt: Date? = nil
  ) -> Int {
    let previous = states[id]
    // A previous outcome recorded against a different URL belongs to a webhook that no
    // longer exists at this id, so its failure streak does not carry over.
    let sameEndpoint = previous?.url == url
    let carried = sameEndpoint ? (previous?.consecutiveFailures ?? 0) : 0
    let failures = outcome.isFailure ? carried + 1 : 0
    let backlog: (waiting: Int, next: Date?)
    if let waiting {
      backlog = (waiting, nextAttemptAt)
    } else if sameEndpoint, let previous {
      backlog = (previous.waiting, previous.nextAttemptAt)
    } else {
      backlog = (0, nil)
    }

    states[id] = WebhookDeliveryState(
      outcome: outcome, at: at, consecutiveFailures: failures, event: event, url: url,
      waiting: backlog.waiting, nextAttemptAt: backlog.next
    )
    publish()
    return failures
  }

  /// Updates how many events are waiting for an endpoint without recording an attempt:
  /// an event queued behind a failure, or an outbox discarded. A state recorded against
  /// another URL is left alone, as `record` leaves its streak.
  public func noteBacklog(id: Int64, url: String, waiting: Int, nextAttemptAt: Date?) {
    guard let previous = states[id], previous.url == url else { return }
    states[id] = WebhookDeliveryState(
      outcome: previous.outcome, at: previous.at,
      consecutiveFailures: previous.consecutiveFailures, event: previous.event, url: url,
      waiting: waiting, nextAttemptAt: nextAttemptAt
    )
    publish()
  }

  public func state(for id: Int64) -> WebhookDeliveryState? { states[id] }

  public func all() -> [Int64: WebhookDeliveryState] { states }

  public func forget(_ id: Int64) {
    states[id] = nil
    publish()
  }
}

// MARK: - Sending

public enum WebhookDelivery {

  /// The same on every attempt at one event, so a receiver can drop a duplicate: the case a
  /// retry cannot avoid is a response lost after the endpoint had already done the work.
  public static let deliveryIDHeader = "X-BlueBubbles-Delivery-Id"
  /// 1 for the first attempt, 2 for the first retry, and so on.
  public static let attemptHeader = "X-BlueBubbles-Delivery-Attempt"

  /// Encodes one event for one target and POSTs it.
  ///
  /// Shared by `WebhookSink` and the test send. The subscription is NOT consulted here:
  /// the caller decides who gets this event, which is what lets a test send reach an
  /// endpoint that is subscribed to something narrow without pretending it is subscribed to
  /// the test.
  ///
  /// - Parameters:
  ///   - deliveryID: what identifies this event to this endpoint across attempts. A fresh
  ///     one for a send that will never be retried, which is the test send.
  ///   - attempt: which attempt this is, from 1.
  public static func send(
    _ event: ServerEvent,
    to target: WebhookTarget,
    negotiator: CodecNegotiator,
    transport: any HTTPPosting,
    projection: PayloadProjection = .notification,
    deliveryID: UUID = UUID(),
    attempt: Int = 1
  ) async throws {
    let capabilities = TargetCapabilities(supportedCodecs: target.codecs)
    let codec = negotiator.resolve(for: capabilities)
    let encoded = try await codec.encode(
      event, projection: projection, capabilities: capabilities
    )
    // The frozen body shape: `{"type": "<event-name>", "data": <payload>}`.
    let body = try JSONValue.object([
      "type": .string(event.name.rawValue),
      "data": encoded.body,
    ]).serialize()

    try await transport.post(
      url: target.url,
      body: body,
      headers: [
        "Content-Type": "application/json",
        deliveryIDHeader: deliveryID.uuidString.lowercased(),
        attemptHeader: String(attempt),
      ],
      followRedirects: target.followRedirects
    )
  }

  /// The event a test send delivers.
  ///
  /// `hello-world` because nothing else in the server ever emits it: it is in the
  /// subscribable vocabulary and has no producer, so a consumer that receives one knows
  /// with certainty that a person pressed a button, rather than having to tell a synthetic
  /// `new-message` apart from a real one.
  public static func testEvent(at date: Date = Date()) -> ServerEvent {
    ServerEvent(
      name: .helloWorld,
      fullPayload: .object([
        "test": .bool(true),
        "message": .string("This is a test event from the BlueBubbles server."),
        "sentAt": .int64(Int64(date.timeIntervalSince1970 * 1000)),
      ]),
      occurredAt: date
    )
  }
}
