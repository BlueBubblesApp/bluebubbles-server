//  WebhookDeliveryTests
//  Delivery outcomes, the failure streak, and the test send.
//
//  The streak is the part worth pinning: it is what the settings row shows AND what the
//  persistent-failure alert fires on, and those two disagreeing would mean a row saying an
//  endpoint is fine beside an alert saying it has failed ten times.
//
//  The test send is pinned against the same `WebhookDelivery.send` real dispatch uses, because
//  the one useless version of this feature is a test that exercises its own code path and
//  passes while delivery is broken.

import BBSerialization
import Foundation
import Testing

@testable import BBEvents

/// Records what was posted, and can be told to fail.
private actor RecordingTransport: HTTPPosting {
  private(set) var posts: [(url: String, body: Data, followRedirects: Bool)] = []
  private var failure: (any Error)?

  init(failing: (any Error)? = nil) { self.failure = failing }

  func fail(with error: (any Error)?) { failure = error }

  func post(
    url: String, body: Data, headers: [String: String], followRedirects: Bool
  ) async throws {
    if let failure { throw failure }
    posts.append((url, body, followRedirects))
  }
}

@Suite("Webhook delivery")
struct WebhookDeliveryTests {

  private func target(_ events: [String] = ["*"]) -> WebhookTarget {
    WebhookTarget(id: 1, url: "https://example.com/hook", events: events)
  }

  // MARK: - The redirect policy

  /// The target's switch has to reach the transport, because that is the only place it does
  /// anything: `URLSession` follows redirects unless a delegate says otherwise, so a policy
  /// that stops at the target struct is a policy that is not applied.
  @Test("A target's redirect policy is what the transport is told")
  func redirectPolicyReachesTheTransport() async throws {
    let transport = RecordingTransport()
    for allowed in [false, true] {
      try await WebhookDelivery.send(
        WebhookDelivery.testEvent(),
        to: WebhookTarget(
          id: 1, url: "https://example.com/hook", events: ["*"], followRedirects: allowed
        ),
        negotiator: .legacyOnly(),
        transport: transport
      )
    }
    #expect(await transport.posts.map(\.followRedirects) == [false, true])
  }

  /// Off unless asked for. A webhook registered over the API is registered by anything
  /// holding the server password, and the URL is the whole of what was approved.
  @Test("A target says no to redirects unless it was built saying yes")
  func redirectsAreOffByDefault() {
    #expect(
      WebhookTarget(id: 1, url: "https://example.com/hook", events: ["*"])
        .followRedirects == false)
  }

  // MARK: - Following

  @Test("A recorded outcome reaches a follower as the whole table, and so does a forget")
  func changesStream() async {
    // The settings page polled `all()` on a timer because there was nothing to follow. A
    // follower gets the table, not the row, so it holds exactly what `all()` would return.
    let tracker = WebhookDeliveryTracker()
    let changes = await tracker.changes()
    var iterator = changes.makeAsyncIterator()

    await tracker.record(
      id: 1, url: "https://example.com/hook", event: "new-message", outcome: .delivered)
    let afterRecord = await iterator.next()
    #expect(afterRecord?[1]?.outcome == .delivered)
    #expect(afterRecord?.count == 1)

    await tracker.forget(1)
    let afterForget = await iterator.next()
    #expect(afterForget?.isEmpty == true)
  }

  // MARK: - The wire body

  @Test("The posted body keeps the frozen shape")
  func bodyShape() async throws {
    let transport = RecordingTransport()
    let event = ServerEvent(name: .newMessage, fullPayload: .object(["guid": .string("A")]))

    try await WebhookDelivery.send(
      event, to: target(), negotiator: .legacyOnly(), transport: transport
    )

    let posts = await transport.posts
    #expect(posts.count == 1)
    #expect(posts[0].url == "https://example.com/hook")

    // `{"type": "<event-name>", "data": <payload>}`: consumers parse this, so it does
    // not change.
    let parsed = try JSONValue.parse(posts[0].body)
    #expect(parsed["type"]?.stringValue == "new-message")
    #expect(parsed["data"]?["guid"]?.stringValue == "A")
  }

  @Test("A test send reaches an endpoint subscribed to something else")
  func testSendIgnoresSubscription() async throws {
    let transport = RecordingTransport()
    // Subscribed to new-message only. The button is a check of whether the URL answers,
    // and refusing to test a narrowly subscribed endpoint would make it useless exactly
    // where someone is most likely to press it.
    let narrow = target(["new-message"])

    try await WebhookDelivery.send(
      WebhookDelivery.testEvent(), to: narrow, negotiator: .legacyOnly(),
      transport: transport
    )

    let posts = await transport.posts
    #expect(posts.count == 1)
    let parsed = try JSONValue.parse(posts[0].body)
    #expect(parsed["type"]?.stringValue == "hello-world")
    // Marked as a test in the payload: nothing else in the server emits `hello-world`,
    // and the flag means a consumer never has to guess.
    #expect(parsed["data"]?["test"]?.boolValue == true)
  }

  // MARK: - The streak

  @Test("Failures accumulate and a success clears them")
  func streak() async {
    let tracker = WebhookDeliveryTracker()
    let url = "https://example.com/hook"

    #expect(
      await tracker.record(id: 1, url: url, event: "new-message", outcome: .failed("HTTP 500")) == 1
    )
    #expect(
      await tracker.record(id: 1, url: url, event: "new-message", outcome: .failed("HTTP 500")) == 2
    )
    #expect(await tracker.record(id: 1, url: url, event: "new-message", outcome: .delivered) == 0)

    let state = await tracker.state(for: 1)
    #expect(state?.outcome == .delivered)
    #expect(state?.consecutiveFailures == 0)
  }

  @Test("A different URL at the same id does not inherit the old streak")
  func streakDoesNotCrossEndpoints() async {
    // SQLite reuses row ids after a delete. Carrying the previous endpoint's failures
    // onto a newly registered one would report it as broken before it was ever tried.
    let tracker = WebhookDeliveryTracker()
    await tracker.record(
      id: 1, url: "https://old.example.com", event: "new-message",
      outcome: .failed("HTTP 404"))
    await tracker.record(
      id: 1, url: "https://old.example.com", event: "new-message",
      outcome: .failed("HTTP 404"))

    let count = await tracker.record(
      id: 1, url: "https://new.example.com", event: "new-message",
      outcome: .failed("HTTP 500")
    )
    #expect(count == 1)
  }

  @Test("The recorded state names the event and the endpoint")
  func recordsContext() async {
    let tracker = WebhookDeliveryTracker()
    await tracker.record(
      id: 7, url: "https://example.com/hook", event: "typing-indicator",
      outcome: .failed("HTTP 404"))
    let state = await tracker.state(for: 7)
    #expect(state?.event == "typing-indicator")
    #expect(state?.url == "https://example.com/hook")
    #expect(state?.outcome == .failed("HTTP 404"))
  }

  // MARK: - Reasons

  @Test("Failure reasons are short enough to show in a row")
  func reasons() {
    #expect(
      WebhookDeliveryState.reason(for: URLSessionPoster.PostError.httpStatus(404))
        == "HTTP 404"
    )
    #expect(
      WebhookDeliveryState.reason(for: URLSessionPoster.PostError.invalidURL("nope"))
        == "Not a valid URL"
    )
  }

  // MARK: - The sink writes to the tracker

  @Test("Real dispatch records its outcome where the UI reads it")
  func sinkRecords() async throws {
    let tracker = WebhookDeliveryTracker()
    let transport = RecordingTransport()
    let hook = target()
    let sink = WebhookSink(
      targets: { [hook] }, transport: transport, deliveries: tracker
    )

    try await sink.deliver(
      ServerEvent(name: .newMessage, fullPayload: .object([:]))
    )
    #expect(await tracker.state(for: 1)?.outcome == .delivered)

    // And a failure lands there too, with the reason the row will show.
    await transport.fail(with: URLSessionPoster.PostError.httpStatus(404))
    try await sink.deliver(
      ServerEvent(name: .newMessage, fullPayload: .object([:]))
    )
    let state = await tracker.state(for: 1)
    #expect(state?.outcome == .failed("HTTP 404"))
    #expect(state?.consecutiveFailures == 1)
  }

  // MARK: - The chat filter

  /// The filter has to reach the sink's own choice of targets: a scope that stops at the
  /// target struct is one that delivers every conversation anyway.
  @Test("A chat event goes only to the endpoints following that conversation")
  func sinkAppliesChatScope() async throws {
    let transport = RecordingTransport()
    let chosen = "iMessage;-;+12025550143"
    let targets = [
      WebhookTarget(id: 1, url: "https://example.com/all", events: ["*"]),
      WebhookTarget(
        id: 2, url: "https://example.com/chosen", events: ["*"], chatScope: .only([chosen])),
      WebhookTarget(
        id: 3, url: "https://example.com/other", events: ["*"],
        chatScope: .only(["iMessage;-;someone@example.com"])),
    ]
    let sink = WebhookSink(targets: { targets }, transport: transport)
    let message = ServerEvent(
      name: .newMessage,
      fullPayload: .object(["chats": .array([.object(["guid": .string(chosen)])])]))

    #expect(await sink.accepts(message))
    try await sink.deliver(message)
    let delivered = Set(await transport.posts.map(\.url))
    #expect(delivered == ["https://example.com/all", "https://example.com/chosen"])

    // And an event that is not about a conversation reaches all three.
    let before = await transport.posts.count
    try await sink.deliver(ServerEvent(name: .serverUpdate, fullPayload: .string("1.2.3")))
    #expect(await transport.posts.count == before + 3)
  }

  @Test("A sink whose every endpoint follows other conversations does not accept the event")
  func sinkDeclinesUnfollowedChat() async {
    let narrowed = WebhookTarget(
      id: 1, url: "https://example.com/hook", events: ["*"],
      chatScope: .only(["iMessage;-;someone@example.com"]))
    let sink = WebhookSink(targets: { [narrowed] }, transport: RecordingTransport())
    let typing = ServerEvent(
      name: .typingIndicator,
      fullPayload: .object(["guid": .string("any;-;+12025550143"), "display": .bool(true)]))
    #expect(await sink.accepts(typing) == false)
  }
}

@Suite("ntfy subscriptions")
struct NtfySubscriptionTests {

  @Test("An ntfy target can be narrowed the same way a webhook can")
  func filters() {
    // The capability was always there; nothing ever supplied it, so every install got the
    // wildcard whether or not that was wanted.
    let target = NtfyTarget(topic: "bb", events: ["new-message"])
    #expect(target.matches(.newMessage))
    #expect(!target.matches(.typingIndicator))
    #expect(!target.matches(.newFindMyLocation))
  }

  @Test("The wildcard still means everything")
  func wildcard() {
    let target = NtfyTarget(topic: "bb")
    #expect(target.matches(.newMessage))
    #expect(target.matches(.typingIndicator))
  }
}
