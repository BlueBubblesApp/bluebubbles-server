//  WebhookDelivery
//  Whether an endpoint is actually receiving anything, and a way to find out on purpose.
//
//  `WebhookSink` has always counted consecutive failures and raised an alert on the tenth, and
//  that count lived in a private field inside the actor. So the one question anyone has about
//  a webhook — is it working? — could only be answered by waiting for ten events to fail, and
//  the commonest failure of all is a URL with a typo in it that never fires and never says so.
//  A registered endpoint that is silently dead looks exactly like a quiet one.
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
    /// A short human reason — "HTTP 404", "Could not connect to the server". Never the
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
  /// What this outcome was recorded against — see the file comment on reused row ids.
  public let url: String

  public init(
    outcome: Outcome, at: Date, consecutiveFailures: Int, event: String, url: String
  ) {
    self.outcome = outcome
    self.at = at
    self.consecutiveFailures = consecutiveFailures
    self.event = event
    self.url = url
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
/// observed since it started, which is the honest scope — persisting it would mean showing
/// "delivered" for an endpoint that was last reached before a reboot three weeks ago.
public actor WebhookDeliveryTracker {

  private var states: [Int64: WebhookDeliveryState] = [:]

  public init() {}

  /// Records an attempt and returns the consecutive failure count after it.
  ///
  /// The count lives here rather than in the sink so that every path that delivers — real
  /// dispatch and the test send — moves the same counter. A successful test send clearing
  /// the failure streak is correct: the endpoint just answered.
  @discardableResult
  public func record(
    id: Int64,
    url: String,
    event: String,
    outcome: WebhookDeliveryState.Outcome,
    at: Date = Date()
  ) -> Int {
    let previous = states[id]
    // A previous outcome recorded against a different URL belongs to a webhook that no
    // longer exists at this id, so its failure streak does not carry over.
    let carried = previous?.url == url ? (previous?.consecutiveFailures ?? 0) : 0
    let failures = outcome.isFailure ? carried + 1 : 0

    states[id] = WebhookDeliveryState(
      outcome: outcome, at: at, consecutiveFailures: failures, event: event, url: url
    )
    return failures
  }

  public func state(for id: Int64) -> WebhookDeliveryState? { states[id] }

  public func all() -> [Int64: WebhookDeliveryState] { states }

  public func forget(_ id: Int64) { states[id] = nil }
}

// MARK: - Sending

public enum WebhookDelivery {

  /// Encodes one event for one target and POSTs it.
  ///
  /// Shared by `WebhookSink` and the test send. The subscription is NOT consulted here —
  /// the caller decides who gets this event, which is what lets a test send reach an
  /// endpoint that is subscribed to something narrow without pretending it is subscribed to
  /// the test.
  public static func send(
    _ event: ServerEvent,
    to target: WebhookTarget,
    negotiator: CodecNegotiator,
    transport: any HTTPPosting,
    projection: PayloadProjection = .notification
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

    try await transport.post(url: target.url, body: body)
  }

  /// The event a test send delivers.
  ///
  /// `hello-world` because nothing else in the server ever emits it — it is in the
  /// subscribable vocabulary and has no producer — so a consumer that receives one knows
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
