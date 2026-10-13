//  AuditRepeatLimiterTests
//  A refused client costs one row a minute, and the rest are counted, never lost.
//
//  The limiter exists because a refusal is free to send and a row per refusal let any client
//  that can reach the server fill `app.db` at the rate it could send. What has to hold is
//  both halves: the rows stay bounded, and the count of what was not stored is exact, so an
//  auditor can still say how many refusals there were.

import BBCore
import BBPersistence
import Foundation
import Testing

@testable import BBAudit

@Suite("Audit repeat limiter")
struct AuditRepeatLimiterTests {

  private static let start = Date(timeIntervalSince1970: 1_700_000_000)

  private func refusal(
    _ kind: AuditEventKind = .requestBlocked,
    client: String = "203.0.113.9",
    route: String = "/api/v1/server/info",
    at seconds: TimeInterval,
    from start: Date = Self.start
  ) -> AuditEvent {
    AuditEvent(
      kind: kind, outcome: .denied, actor: .client(address: client), source: .http,
      route: route, subject: .client(client), summary: "refused",
      occurredAt: start.addingTimeInterval(seconds))
  }

  @Test("Only a client's refusals are limited")
  func onlyClientRefusals() {
    #expect(AuditRepeatLimiter.isLimited(refusal(at: 0)))
    let success = AuditEvent(
      kind: .apiRequest, outcome: .success, actor: .client(address: "203.0.113.9"),
      summary: "ok")
    #expect(!AuditRepeatLimiter.isLimited(success))
    let failure = AuditEvent(
      kind: .apiRequest, outcome: .failure, actor: .client(address: "203.0.113.9"),
      summary: "500")
    #expect(!AuditRepeatLimiter.isLimited(failure))
    let operatorRefused = AuditEvent(
      kind: .scopeRefused, outcome: .denied, actor: .operator, summary: "no")
    #expect(!AuditRepeatLimiter.isLimited(operatorRefused))
  }

  @Test("The first refusal in a window is kept and the repeats are counted, not kept")
  func firstKeptRestCounted() {
    var limiter = AuditRepeatLimiter()
    #expect(limiter.admit(refusal(at: 0)).keep)
    for second in 1...500 {
      let decision = limiter.admit(refusal(at: Double(second) / 10))
      #expect(!decision.keep)
      #expect(decision.summaries.isEmpty)
    }
  }

  @Test("When the window closes, one summary carries the exact count and span")
  func summaryOnClose() throws {
    var limiter = AuditRepeatLimiter()
    _ = limiter.admit(refusal(at: 0))
    for second in 1...41 { _ = limiter.admit(refusal(at: Double(second))) }

    // The next refusal after the window opens a new one, and the old one's summary comes
    // out first.
    let next = limiter.admit(refusal(at: AuditRepeatLimiter.window + 5))
    #expect(next.keep)
    let summary = try #require(next.summaries.first)
    #expect(next.summaries.count == 1)
    #expect(summary.kind == .repeatsSuppressed)
    #expect(summary.outcome == .denied)
    #expect(summary.actor == .client(address: "203.0.113.9"))
    #expect(summary.route == "/api/v1/server/info")
    #expect(summary.metadata["suppressed_count"] == .int(41))
    #expect(summary.metadata["repeated_kind"] == .string("auth.request_blocked"))
    #expect(summary.metadata["first_at"] == .string("2023-11-14T22:13:21.000Z"))
    #expect(summary.metadata["last_at"] == .string("2023-11-14T22:14:01.000Z"))
    #expect(summary.occurredAt == Self.start.addingTimeInterval(41))
  }

  @Test("A window with no repeats closes without a summary")
  func noRepeatsNoSummary() {
    var limiter = AuditRepeatLimiter()
    _ = limiter.admit(refusal(at: 0))
    #expect(limiter.nextSummaryDue == nil)
    #expect(limiter.close(before: Self.start.addingTimeInterval(120)).isEmpty)
    #expect(limiter.openWindowCount == 0)
  }

  @Test("Kind, client and route each get their own window")
  func keysAreIndependent() {
    var limiter = AuditRepeatLimiter()
    #expect(limiter.admit(refusal(at: 0)).keep)
    #expect(limiter.admit(refusal(.credentialRejected, at: 1)).keep)
    #expect(limiter.admit(refusal(client: "198.51.100.7", at: 2)).keep)
    #expect(limiter.admit(refusal(route: "/api/v1/webhook", at: 3)).keep)
    #expect(!limiter.admit(refusal(at: 4)).keep)
  }

  @Test("An unlimited record still lets a closed window's summary out")
  func unlimitedEventFlushesSummaries() {
    var limiter = AuditRepeatLimiter()
    _ = limiter.admit(refusal(at: 0))
    _ = limiter.admit(refusal(at: 1))
    let other = AuditEvent(
      kind: .settingsChanged, summary: "x",
      occurredAt: Self.start.addingTimeInterval(AuditRepeatLimiter.window + 1))
    let decision = limiter.admit(other)
    #expect(decision.keep)
    #expect(decision.summaries.map(\.kind) == [.repeatsSuppressed])
  }

  @Test("Past the bound, the oldest window closes early and its count is reported")
  func boundedByEvictingOldest() {
    var limiter = AuditRepeatLimiter()
    _ = limiter.admit(refusal(client: "client-0", at: 0))
    _ = limiter.admit(refusal(client: "client-0", at: 0.5))
    for index in 1..<AuditRepeatLimiter.maximumOpenWindows {
      _ = limiter.admit(refusal(client: "client-\(index)", at: 1))
    }
    #expect(limiter.openWindowCount == AuditRepeatLimiter.maximumOpenWindows)

    let decision = limiter.admit(refusal(client: "one-too-many", at: 2))
    #expect(decision.keep)
    #expect(limiter.openWindowCount == AuditRepeatLimiter.maximumOpenWindows)
    #expect(decision.summaries.count == 1)
    #expect(decision.summaries.first?.actor == .client(address: "client-0"))
    #expect(decision.summaries.first?.metadata["suppressed_count"] == .int(1))
  }

  @Test("A summary never joins to the request that happened to close its window")
  func summaryCarriesNoRequest() async throws {
    var limiter = AuditRepeatLimiter()
    _ = limiter.admit(refusal(at: 0))
    _ = limiter.admit(refusal(at: 1))
    let unrelated = AuditContext(
      actor: .client(address: "198.51.100.7"), source: .http, requestID: "unrelated",
      route: "/api/v1/webhook")
    let summaries = AuditContext.$current.withValue(unrelated) {
      limiter.close(before: Self.start.addingTimeInterval(AuditRepeatLimiter.window))
    }
    #expect(summaries.count == 1)
    #expect(summaries.first?.requestID == nil)
    #expect(summaries.first?.route == "/api/v1/server/info")
  }

  // MARK: - Through the recorder

  @Test("A flood through the recorder stores one record, and its count when recording stops")
  func floodThroughTheRecorder() async throws {
    let repository = AuditRepository(
      database: try AppDatabase.inMemory(contributors: [AuditSchema.self]))
    let recorder = AuditRecorder()
    await recorder.arm(store: repository)

    // Dated from NOW: the recorder closes windows on the wall clock, so a flood stamped in
    // the past would find every window already over.
    let now = Date()
    for index in 0..<2_000 {
      await recorder.recordNow(refusal(at: Double(index) / 1_000, from: now))
    }
    await recorder.drain()
    #expect(try await repository.count() == 1)

    await recorder.disarm()
    let page = try await repository.page(limit: 10, offset: 0)
    #expect(page.total == 2)
    let summary = try #require(page.events.first { $0.kind == .repeatsSuppressed })
    #expect(summary.metadata["suppressed_count"] == .int(1_999))
  }
}
