//  ServerMetricsTests
//  The dashboard's numbers: what is counted, how a minute is rolled up, what is kept and for
//  how long, and that the server actually feeds all of it.

import BBAppStore
import BBCore
import BBEvents
import BBHTTPAPI
import BBPersistence
import BBPrivateAPIContract
import BBPushKit
import BBTestSupport
import Foundation
import Testing

import struct os.OSAllocatedUnfairLock

@testable import BlueBubblesServerCore

@Suite("Server metrics")
struct ServerMetricsTests {

  /// On a minute boundary, so "the minute this started in" is unambiguous.
  private static let start = Date(timeIntervalSince1970: 1_700_000_040)

  /// Live values a test sets by hand.
  private final class Live: Sendable {
    let clients = OSAllocatedUnfairLock(initialState: 0)
    let helpers = OSAllocatedUnfairLock(initialState: Set<String>())
  }

  private struct Harness {
    let metrics: ServerMetrics
    let store: MetricsStore
    let clock: ManualClock
    let requests: RequestMetrics
    let live: Live
  }

  private static func harness(store: MetricsStore? = nil) async throws -> Harness {
    let clock = ManualClock(start)
    let database = try AppDatabase.inMemory(contributors: [MetricsSchema.self])
    let store = store ?? MetricsStore(database: database)
    let requests = RequestMetrics()
    let live = Live()
    let metrics = ServerMetrics(store: store, clock: clock)
    await metrics.start(
      sources: ServerMetrics.Sources(
        socketClients: { live.clients.withLock { $0 } },
        requests: { await requests.snapshot() },
        helpers: { live.helpers.withLock { $0 } },
        memoryBytes: { 100 * 1_048_576 },
        cpuSeconds: { nil }),
      ticking: false)
    return Harness(metrics: metrics, store: store, clock: clock, requests: requests, live: live)
  }

  @Test("Requests, events and pushes are counted since start")
  func countsSinceStart() async throws {
    let h = try await Self.harness()
    for (route, milliseconds, failed) in [
      ("/api/v1/ping", 10, false), ("/api/v1/ping", 30, true), ("/api/v1/chat", 20, false),
    ] {
      await h.requests.record(
        routeTemplate: route, duration: .milliseconds(milliseconds), failed: failed)
    }
    h.metrics.noteDispatched(.newMessage)
    h.metrics.noteDispatched(.newMessage)
    h.metrics.noteDispatched(EventName("typing-indicator"))
    h.metrics.notePush(
      DeliveryReport(outcomes: ["a": .delivered, "b": .delivered, "c": .tokenExpired]))

    h.clock.advance(by: 30)
    await h.metrics.tick()
    let snapshot = try #require(await h.metrics.snapshot)
    #expect(snapshot.requests == 3)
    #expect(snapshot.requestErrors == 1)
    #expect(snapshot.averageLatencyMilliseconds == 20)
    #expect(snapshot.busiestRoutes.first?.template == "/api/v1/ping")
    #expect(snapshot.newMessages == 2)
    #expect(snapshot.eventsDispatched == 3)
    #expect(snapshot.pushDelivered == 2)
    #expect(snapshot.pushFailed == 1)
    #expect(snapshot.pushExpired == 1)
    #expect(snapshot.uptime == 30)
  }

  @Test("A finished minute holds that minute's difference, and is written to the store")
  func rollsUpAMinute() async throws {
    let h = try await Self.harness()
    h.live.clients.withLock { $0 = 2 }
    await h.requests.record(routeTemplate: "/a", duration: .milliseconds(10), failed: false)
    h.metrics.noteDispatched(.newMessage)
    h.clock.advance(by: 30)
    await h.metrics.tick()
    h.live.clients.withLock { $0 = 1 }

    // Into the next minute: the first one is finished.
    h.clock.advance(by: 40)
    await h.metrics.tick()
    let first = try #require(await h.metrics.snapshot?.recent.first)
    #expect(first.start == Self.start)
    #expect(first.value(.requests) == 1)
    #expect(first.value(.newMessages) == 1)
    // The most connected at once during the minute, not the last reading.
    #expect(first.value(.socketClients) == 2)
    #expect(first.value(.memoryMegabytes) == 100)

    // The second minute counts only what happened in it.
    await h.requests.record(routeTemplate: "/a", duration: .milliseconds(10), failed: false)
    await h.requests.record(routeTemplate: "/a", duration: .milliseconds(10), failed: false)
    h.clock.advance(by: 60)
    await h.metrics.tick()
    let recent = try #require(await h.metrics.snapshot?.recent)
    #expect(recent.map { $0.value(.requests) } == [1, 2])

    let stored = try await h.store.series(.requests, since: Self.start)
    #expect(stored.map(\.value) == [1, 2])
  }

  @Test("A helper's availability opens and closes with its connection")
  func helperSpans() async throws {
    let h = try await Self.harness()
    h.live.helpers.withLock { $0 = [HelperHost.messages] }
    h.clock.advance(by: 5)
    await h.metrics.tick()
    #expect(await h.metrics.snapshot?.isMessagesHelperConnected == true)
    #expect(await h.metrics.snapshot?.isFaceTimeHelperConnected == false)

    h.live.helpers.withLock { $0 = [] }
    h.clock.advance(by: 5)
    await h.metrics.tick()

    let spans = try await h.metrics.availability(since: Self.start)
    let messages = try #require(spans.first { $0.subject == .messagesHelper })
    #expect(messages.end == Self.start.addingTimeInterval(10))
    // The server's own span is still open.
    #expect(spans.first { $0.subject == .server }?.end == nil)
  }

  @Test("Stopping closes every span, and a span a crash left open is closed at the next start")
  func spansAreClosed() async throws {
    let database = try AppDatabase.inMemory(contributors: [MetricsSchema.self])
    let store = MetricsStore(database: database)
    // A previous run: up an hour before, last flushed ten minutes before, then gone.
    let crashedStart = Self.start.addingTimeInterval(-3_600)
    let lastFlush = Self.start.addingTimeInterval(-600)
    _ = try await store.open(.server, at: crashedStart)
    try await store.record(minute: lastFlush, values: [.requests: 1])

    let h = try await Self.harness(store: store)
    let spans = try await store.spans(since: crashedStart)
    let crashed = try #require(spans.first { $0.start == crashedStart })
    // The last minute anyone can vouch for, not the moment this run started.
    #expect(crashed.end == lastFlush.addingTimeInterval(60))

    h.clock.advance(by: 90)
    await h.metrics.stop()
    let after = try await store.spans(since: Self.start)
    #expect(after.allSatisfy { $0.end != nil })
  }

  @Test("Nothing older than the retention window survives a prune, and an open span always does")
  func retention() async throws {
    let database = try AppDatabase.inMemory(contributors: [MetricsSchema.self])
    let store = MetricsStore(database: database)
    let now = Self.start
    let old = now.addingTimeInterval(-MetricsStore.retention - 60)
    try await store.record(minute: old, values: [.requests: 5])
    try await store.record(minute: now, values: [.requests: 1])
    let closed = try await store.open(.messagesHelper, at: old)
    try await store.close(span: closed, at: old.addingTimeInterval(30))
    _ = try await store.open(.server, at: old)

    try await store.prune(before: now.addingTimeInterval(-MetricsStore.retention))

    #expect(try await store.series(.requests, since: .distantPast).map(\.value) == [1])
    let spans = try await store.spans(since: .distantPast)
    #expect(spans.map(\.subject) == [.server])
  }

  @Test("The bus reports every dispatched event, including one no sink takes")
  func busObserverCounts() async throws {
    let h = try await Self.harness()
    let bus = EventBus()
    let metrics = h.metrics
    await bus.setDispatchObserver { metrics.noteDispatched($0) }
    await bus.emit(
      ServerEvent(name: .newMessage, fullPayload: .object([:]), notificationPayload: .object([:])))
    h.clock.advance(by: 5)
    await h.metrics.tick()
    #expect(await h.metrics.snapshot?.newMessages == 1)
  }

  // MARK: - Wiring

  /// A module is not done until the composition root calls it. Each of these is the one line
  /// that, deleted, leaves every part above passing and the dashboard reading zero.
  @Test("The server starts and stops the metrics, and every source feeds them")
  func wiring() throws {
    func source(_ path: String) throws -> String { try Repository.read(path) }
    // The whole family: the composition root is one type split across extension files.
    let composition = try SourceScanner.family(
      "Sources/BlueBubblesServerCore/Composition/ServerComposition.swift"
    ).text
    #expect(composition.contains("setDispatchObserver { metrics.noteDispatched($0) }"))
    #expect(composition.contains("await metrics.start(sources: context.metricSources())"))
    #expect(composition.contains("await context.metrics.stop()"))

    let http = try source(
      "Sources/BlueBubblesServerCore/Composition/Services/HTTPService.swift")
    #expect(http.contains("metrics: host.requestMetrics"))

    let push = try source(
      "Sources/BlueBubblesServerCore/Composition/Services/PushDeliveryService.swift")
    #expect(push.contains("metrics.notePush(report)"))

    let schema = try source("Sources/BlueBubblesServerCore/Composition/AppSchema.swift")
    #expect(schema.contains("MetricsSchema.self"))
  }
}
