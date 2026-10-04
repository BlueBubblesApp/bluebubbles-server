//  WebhookRetryTests
//  Retrying failed webhook deliveries: the policy, the outbox, and the sink driving them.
//
//  What matters is what an endpoint's owner would see. An event that failed arrives later,
//  exactly once more per attempt and with the same delivery ID; events that happened while
//  the endpoint was down arrive after it, in order; a refusal that a retry cannot change is
//  not retried; and nothing about one failing endpoint reaches another.
//
//  The sink's timer is switched off throughout, and the outboxes are drained by calling
//  `runDueRetries(at:)` with a time far enough ahead. Waiting for the real clock would make
//  every one of these a race.

import BBSerialization
import Foundation
import Testing

@testable import BBEvents

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Records every POST, failed ones included, and fails the URLs it is told to.
private actor ScriptedTransport: HTTPPosting {
  struct Post: Sendable {
    let url: String
    let type: String?
    let deliveryID: String?
    let attempt: String?
  }

  private(set) var posts: [Post] = []
  private var failures: [String: any Error] = [:]

  func fail(_ url: String, with error: (any Error)?) { failures[url] = error }

  func post(
    url: String, body: Data, headers: [String: String], followRedirects: Bool
  ) async throws {
    posts.append(
      Post(
        url: url,
        type: (try? JSONValue.parse(body))?["type"]?.stringValue,
        deliveryID: headers[WebhookDelivery.deliveryIDHeader],
        attempt: headers[WebhookDelivery.attemptHeader]))
    if let failure = failures[url] { throw failure }
  }
}

@Suite("Webhook retries")
struct WebhookRetryTests {

  private static let url = "https://example.com/hook"
  private static let unavailable = URLSessionPoster.PostError.httpStatus(503)
  private static let later = ContinuousClock.now + .seconds(100_000)

  private func target(
    _ policy: WebhookRetryPolicy = .standard, url: String = Self.url, id: Int64 = 1
  ) -> WebhookTarget {
    WebhookTarget(id: id, url: url, events: ["*"], retryPolicy: policy)
  }

  private func event(_ name: EventName) -> ServerEvent {
    ServerEvent(name: name, fullPayload: .object(["guid": .string("message-guid")]))
  }

  private func sink(
    _ targets: [WebhookTarget], transport: ScriptedTransport,
    tracker: WebhookDeliveryTracker = WebhookDeliveryTracker()
  ) async -> WebhookSink {
    let sink = WebhookSink(targets: { targets }, transport: transport, deliveries: tracker)
    await sink.disableRetryTimer()
    return sink
  }

  // MARK: - Policy

  @Test("The wait doubles from the first retry and stops at an hour")
  func backoffDoublesAndCaps() {
    let policy = WebhookRetryPolicy(maxRetries: 10, initialDelaySeconds: 30)
    let waits = (1...9).map { policy.nominalDelay(afterFailures: $0) }
    #expect(
      waits == [30, 60, 120, 240, 480, 960, 1920, 3600, 3600].map { Duration.seconds($0) })
  }

  @Test("Jitter stays within a fifth either side of the nominal wait")
  func jitterIsBounded() {
    let policy = WebhookRetryPolicy.standard
    #expect(policy.delay(afterFailures: 1, jitter: 0) == .seconds(24))
    #expect(policy.delay(afterFailures: 1, jitter: 0.5) == .seconds(30))
    #expect(policy.delay(afterFailures: 1, jitter: 1) == .seconds(36))
  }

  @Test("A policy out of range is clamped rather than refused")
  func policyIsClamped() {
    let policy = WebhookRetryPolicy(maxRetries: 99, initialDelaySeconds: 0)
    #expect(policy.maxRetries == WebhookRetryPolicy.retryRange.upperBound)
    #expect(policy.initialDelaySeconds == WebhookRetryPolicy.initialDelayRange.lowerBound)
    #expect(!WebhookRetryPolicy(maxRetries: -1, initialDelaySeconds: 30).isEnabled)
  }

  @Test("Only failures a later attempt could change are retried")
  func retryableFailures() {
    for status in [408, 425, 429, 500, 502, 503, 504] {
      #expect(
        WebhookRetryPolicy.isRetryable(URLSessionPoster.PostError.httpStatus(status)),
        "\(status)")
    }
    for status in [301, 302, 400, 401, 403, 404, 410, 422] {
      #expect(
        !WebhookRetryPolicy.isRetryable(URLSessionPoster.PostError.httpStatus(status)),
        "\(status)")
    }
    #expect(WebhookRetryPolicy.isRetryable(URLError(.timedOut)))
    #expect(WebhookRetryPolicy.isRetryable(URLError(.cannotConnectToHost)))
    #expect(!WebhookRetryPolicy.isRetryable(URLError(.badURL)))
    #expect(!WebhookRetryPolicy.isRetryable(URLSessionPoster.PostError.invalidURL("x")))
    #expect(!WebhookRetryPolicy.isRetryable(CancellationError()))
  }

  @Test("A typing indicator is never delivered late")
  func typingIsNotRetried() {
    #expect(!WebhookRetryPolicy.retries(.typingIndicator))
    #expect(WebhookRetryPolicy.retries(.newMessage))
  }

  // MARK: - Outbox

  private func entry(_ name: EventName, attempts: Int = 0) -> WebhookOutboxes.Entry {
    WebhookOutboxes.Entry(event: event(name), deliveryID: UUID(), attemptsMade: attempts)
  }

  @Test("A full outbox drops its oldest event, and says so once")
  func capacityDropsOldest() {
    var outboxes = WebhookOutboxes()
    let now = ContinuousClock.now
    outboxes.open(with: entry(.newMessage), id: 1, url: Self.url, delay: .seconds(30), now: now)
    var firstDrops = 0
    for _ in 0..<(WebhookOutboxes.capacity + 5) {
      if outboxes.append(entry(.updatedMessage), id: 1) { firstDrops += 1 }
    }
    #expect(outboxes.waiting(1) == WebhookOutboxes.capacity)
    #expect(firstDrops == 1)
    // The opening event was the oldest, so it is the one that went.
    #expect(outboxes.takeHead(1)?.event.name == .updatedMessage)
  }

  @Test("A due outbox is handed to one drain, not two")
  func takeDueMarksDraining() {
    var outboxes = WebhookOutboxes()
    let now = ContinuousClock.now
    outboxes.open(with: entry(.newMessage), id: 1, url: Self.url, delay: .seconds(30), now: now)
    #expect(outboxes.takeDue(at: now).isEmpty)
    #expect(outboxes.takeDue(at: now + .seconds(60)) == [1])
    #expect(outboxes.takeDue(at: now + .seconds(60)).isEmpty)
    #expect(outboxes.nextWake == nil)
  }

  @Test("An outbox being drained still holds new events back, even with nothing in it")
  func backingOffWhileDraining() {
    var outboxes = WebhookOutboxes()
    let now = ContinuousClock.now
    outboxes.open(with: entry(.newMessage), id: 1, url: Self.url, delay: .seconds(1), now: now)
    _ = outboxes.takeDue(at: now + .seconds(2))
    _ = outboxes.takeHead(1)
    #expect(outboxes.isBackingOff(1, url: Self.url))
    #expect(!outboxes.isBackingOff(1, url: "https://example.com/other"))
    outboxes.finishDraining(1)
    #expect(!outboxes.isBackingOff(1, url: Self.url))
  }

  @Test("A retryable failure goes back to the head until it is out of retries")
  func failedEntriesReturnToTheHead() throws {
    var outboxes = WebhookOutboxes()
    let now = ContinuousClock.now
    let policy = WebhookRetryPolicy(maxRetries: 2, initialDelaySeconds: 30)
    outboxes.open(
      with: entry(.newMessage, attempts: 1), id: 1, url: Self.url, delay: .seconds(30), now: now)
    outboxes.append(entry(.updatedMessage), id: 1)

    var head = try #require(outboxes.takeHead(1))
    head.attemptsMade += 1
    let retry = outboxes.failed(
      head, id: 1, retryable: true, policy: policy, delay: .seconds(60), now: now)
    #expect(retry == .willRetry)
    #expect(outboxes.takeHead(1)?.event.name == .newMessage)

    head.attemptsMade += 1
    let gaveUp = outboxes.failed(
      head, id: 1, retryable: true, policy: policy, delay: .seconds(120), now: now)
    #expect(gaveUp == .gaveUp)
    // Given up on, but the endpoint is still down: the next event waits out the backoff.
    #expect(outboxes.takeHead(1)?.event.name == .updatedMessage)
    #expect(outboxes.failures(1) == 3)
  }

  @Test("A refusal is given up on at once and does not push the schedule out")
  func refusalsAreNotRetried() throws {
    var outboxes = WebhookOutboxes()
    let now = ContinuousClock.now
    outboxes.open(
      with: entry(.newMessage, attempts: 1), id: 1, url: Self.url, delay: .seconds(30), now: now)
    var head = try #require(outboxes.takeHead(1))
    head.attemptsMade += 1
    let result = outboxes.failed(
      head, id: 1, retryable: false, policy: .standard, delay: .seconds(60), now: now)
    #expect(result == .gaveUp)
    #expect(outboxes.failures(1) == 1)
  }

  // MARK: - The sink

  @Test("A failed event is retried with the same delivery ID and the next attempt number")
  func retriedWithTheSameDeliveryID() async throws {
    let transport = ScriptedTransport()
    let tracker = WebhookDeliveryTracker()
    let sink = await sink([target()], transport: transport, tracker: tracker)

    await transport.fail(Self.url, with: Self.unavailable)
    try await sink.deliver(event(.newMessage))
    #expect(await sink.waiting(for: 1) == 1)
    #expect(await tracker.state(for: 1)?.waiting == 1)
    #expect(await tracker.state(for: 1)?.nextAttemptAt != nil)

    await transport.fail(Self.url, with: nil)
    await sink.runDueRetries(at: Self.later)

    let posts = await transport.posts
    #expect(posts.count == 2)
    #expect(posts.map(\.attempt) == ["1", "2"])
    #expect(posts[0].deliveryID != nil)
    #expect(posts[0].deliveryID == posts[1].deliveryID)
    #expect(await sink.waiting(for: 1) == 0)
    #expect(await tracker.state(for: 1)?.outcome == .delivered)
    #expect(await tracker.state(for: 1)?.waiting == 0)
  }

  @Test("Events that arrive while an endpoint is down wait, then arrive in order")
  func backlogKeepsOrder() async throws {
    let transport = ScriptedTransport()
    let sink = await sink([target()], transport: transport)

    await transport.fail(Self.url, with: Self.unavailable)
    try await sink.deliver(event(.newMessage))
    try await sink.deliver(event(.updatedMessage))
    try await sink.deliver(event(.messageSendError))
    // Only the first was tried: the other two queued behind it rather than hitting an
    // endpoint that had just failed.
    #expect(await transport.posts.count == 1)
    #expect(await sink.waiting(for: 1) == 3)

    await transport.fail(Self.url, with: nil)
    await sink.runDueRetries(at: Self.later)

    let delivered = await transport.posts.dropFirst()
    #expect(
      delivered.map(\.type) == ["new-message", "updated-message", "message-send-error"])
    #expect(delivered.map(\.attempt) == ["2", "1", "1"])
    #expect(Set(delivered.compactMap(\.deliveryID)).count == 3)

    // Recovered: the next event goes straight out.
    try await sink.deliver(event(.newMessage))
    #expect(await transport.posts.count == 5)
    #expect(await sink.waiting(for: 1) == 0)
  }

  @Test("A refusal is not retried, and neither is anything when retries are off")
  func notRetried() async throws {
    let transport = ScriptedTransport()
    let refused = await sink([target()], transport: transport)
    await transport.fail(Self.url, with: URLSessionPoster.PostError.httpStatus(404))
    try await refused.deliver(event(.newMessage))
    #expect(await refused.waiting(for: 1) == 0)

    let off = await sink([target(.off)], transport: transport)
    await transport.fail(Self.url, with: Self.unavailable)
    try await off.deliver(event(.newMessage))
    #expect(await off.waiting(for: 1) == 0)
  }

  @Test("An event is given up on after its last retry")
  func givesUp() async throws {
    let transport = ScriptedTransport()
    let policy = WebhookRetryPolicy(maxRetries: 1, initialDelaySeconds: 5)
    let sink = await sink([target(policy)], transport: transport)

    await transport.fail(Self.url, with: Self.unavailable)
    try await sink.deliver(event(.newMessage))
    await sink.runDueRetries(at: Self.later)

    #expect(await transport.posts.map(\.attempt) == ["1", "2"])
    #expect(await sink.waiting(for: 1) == 0)
    // And nothing is left to send, however late it gets.
    await sink.runDueRetries(at: Self.later + .seconds(100_000))
    #expect(await transport.posts.count == 2)
  }

  @Test("A typing indicator does not queue behind a failure")
  func typingDoesNotQueue() async throws {
    let transport = ScriptedTransport()
    let sink = await sink([target()], transport: transport)
    await transport.fail(Self.url, with: Self.unavailable)
    try await sink.deliver(event(.newMessage))
    try await sink.deliver(
      ServerEvent(
        name: .typingIndicator,
        fullPayload: .object(["guid": .string("any;-;+12025550143"), "display": .bool(true)])))
    #expect(await sink.waiting(for: 1) == 1)
  }

  @Test("One endpoint backing off does not hold another")
  func endpointsAreIndependent() async throws {
    let transport = ScriptedTransport()
    let healthy = "https://example.com/healthy"
    let sink = await sink(
      [target(), target(url: healthy, id: 2)], transport: transport)

    await transport.fail(Self.url, with: Self.unavailable)
    try await sink.deliver(event(.newMessage))
    try await sink.deliver(event(.updatedMessage))

    let toHealthy = await transport.posts.filter { $0.url == healthy }
    #expect(toHealthy.map(\.type) == ["new-message", "updated-message"])
    #expect(await sink.waiting(for: 2) == 0)
  }

  @Test("Stopping discards what was waiting and says how much")
  func stopDiscards() async throws {
    let transport = ScriptedTransport()
    let sink = await sink([target()], transport: transport)
    await transport.fail(Self.url, with: Self.unavailable)
    try await sink.deliver(event(.newMessage))
    try await sink.deliver(event(.updatedMessage))

    #expect(await sink.stopRetrying() == 2)
    await transport.fail(Self.url, with: nil)
    await sink.runDueRetries(at: Self.later)
    #expect(await transport.posts.count == 1)
  }
}
