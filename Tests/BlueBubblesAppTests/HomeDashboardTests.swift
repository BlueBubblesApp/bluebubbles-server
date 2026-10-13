//  HomeDashboardTests
//  What Home says about the server, and the summaries it could get wrong.

import BBAppStore
import BBEvents
import BBInterfaces
import BBServiceKit
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Home dashboard")
struct HomeDashboardTests {

  private static var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  // MARK: - Services

  @Test("A switched-off service is counted, not reported as a problem")
  func offIsNotAProblem() {
    // Every install that does not use ngrok has ngrok switched off. Counting that as a
    // problem would put a warning on Home that nobody can clear.
    let rollup = HomeDashboard.rollup(
      [
        ServiceIdentifier("a"): .running,
        ServiceIdentifier("b"): .inactive(reason: "switched off"),
      ],
      name: { $0.rawValue })
    #expect(rollup.running == 1)
    #expect(rollup.off == 1)
    #expect(rollup.problems.isEmpty)
    #expect(rollup.tone == .good)
    #expect(rollup.headline == "1 running")
    #expect(rollup.detail == nil)
    #expect(rollup.footer == "1 running · 1 switched off or waiting")
  }

  @Test("Failed services list ahead of degraded ones, and the level is the worst")
  func problemsAreOrderedWorstFirst() {
    let rollup = HomeDashboard.rollup(
      [
        ServiceIdentifier("socket"): .degraded(reason: "the certificate expires soon"),
        ServiceIdentifier("tunnel"): .failed(reason: "exited"),
        ServiceIdentifier("http"): .running,
      ],
      name: { $0.rawValue.capitalized })
    #expect(rollup.problems.map(\.name) == ["Tunnel", "Socket"])
    #expect(rollup.tone == .problem)
    #expect(rollup.headline == "2 services need attention")
    #expect(rollup.detail == "2 services")
    #expect(rollup.footer == "1 running")
    // The same sentence the Integrations page shows for the same state.
    #expect(rollup.problems.last?.line.text == "Running, but the certificate expires soon.")
  }

  @Test("No services at all reads as unknown, not as healthy")
  func emptyIsUnknown() {
    #expect(HomeDashboard.rollup([:], name: { $0.rawValue }).tone == .informational)
  }

  // MARK: - Attention

  @Test("A startup failure leads, and nothing is listed that does not need acting on")
  func attentionOrder() {
    let items = HomeDashboard.attention(
      startupFailure: "port in use",
      missingPermissions: 2,
      unreadAlerts: 3,
      latestUnreadAlert: "Tunnel failed",
      availableVersion: "2.0")
    #expect(items.map(\.id) == ["startup", "permissions", "alerts", "update"])

    let quiet = HomeDashboard.attention(
      startupFailure: nil, missingPermissions: 0, unreadAlerts: 0, latestUnreadAlert: nil,
      availableVersion: nil)
    #expect(quiet.isEmpty)
  }

  // MARK: - Hourly buckets

  @Test("Every hour in the window is present, including the empty ones")
  func hourlyIncludesEmptyHours() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-01-02T10:30:00Z"))
    let buckets = HomeDashboard.hourly([], now: now, hours: 24, calendar: Self.utc)
    #expect(buckets.count == 24)
    #expect(buckets.allSatisfy { $0.count == 0 })
    #expect(buckets.last?.start == ISO8601DateFormatter().date(from: "2026-01-02T10:00:00Z"))
    #expect(buckets.first?.start == ISO8601DateFormatter().date(from: "2026-01-01T11:00:00Z"))
  }

  @Test("A date is counted in its own hour, and one outside the window is dropped")
  func hourlyBucketsAndDrops() throws {
    let format = ISO8601DateFormatter()
    let now = try #require(format.date(from: "2026-01-02T10:30:00Z"))
    let dates = try [
      "2026-01-02T10:05:00Z", "2026-01-02T10:29:59Z",  // this hour
      "2026-01-02T09:59:59Z",  // the hour before
      "2026-01-01T10:59:59Z",  // one second before the window opens
    ].map { try #require(format.date(from: $0)) }
    let buckets = HomeDashboard.hourly(dates, now: now, hours: 24, calendar: Self.utc)
    #expect(buckets.last?.count == 2)
    #expect(buckets.dropLast().last?.count == 1)
    #expect(buckets.reduce(0) { $0 + $1.count } == 3)
  }

  // MARK: - Library

  @Test("An unknown media kind lands in other rather than vanishing")
  func mediaUnknownKind() {
    let media = HomeDashboard.MediaBreakdown(counts: [
      "image": 5, "video": 2, "location": 1, "sticker": 3, "other": 1,
    ])
    #expect(media == HomeDashboard.MediaBreakdown(images: 5, videos: 2, locations: 1, other: 4))
  }

  // MARK: - Schedule

  @Test("The next send is the soonest pending one, never a sent or cancelled row")
  func scheduleNextDue() {
    let soon = Date(timeIntervalSince1970: 1_000)
    let later = Date(timeIntervalSince1970: 2_000)
    let earlier = Date(timeIntervalSince1970: 500)
    let summary = HomeDashboard.schedule([
      ("pending", later),
      ("pending", soon),
      ("sent", earlier),
      ("cancelled", earlier),
      ("failed", earlier),
    ])
    #expect(summary.pending == 2)
    #expect(summary.failed == 1)
    #expect(summary.nextDue == soon)
  }

  // MARK: - Delivery

  @Test("The most recent device is the latest active one, and a silent device never is")
  func pushMostRecent() {
    let summary = HomeDashboard.push([
      ("Phone", Date(timeIntervalSince1970: 100)),
      ("Tablet", nil),
      ("Laptop", Date(timeIntervalSince1970: 300)),
    ])
    #expect(summary.devices == 3)
    #expect(summary.mostRecent?.name == "Laptop")
    #expect(HomeDashboard.push([("Tablet", nil)]).mostRecent == nil)
  }

  @Test("Only a webhook whose last delivery failed counts as failing")
  func webhookFailing() {
    let failed = WebhookDeliveryState(
      outcome: .failed("HTTP 500"), at: .now, consecutiveFailures: 2, event: "new-message",
      url: "https://example.com/a")
    let delivered = WebhookDeliveryState(
      outcome: .delivered, at: .now, consecutiveFailures: 0, event: "new-message",
      url: "https://example.com/b")
    let summary = HomeDashboard.webhooks(registered: 3, deliveries: [1: failed, 2: delivered])
    #expect(summary == HomeDashboard.WebhookSummary(registered: 3, failing: 1))
    #expect(summary.tone == .attention)
    // A tracker entry for a deleted row cannot push the failing count past the table's.
    #expect(HomeDashboard.webhooks(registered: 0, deliveries: [1: failed]).failing == 0)
  }

  // MARK: - Tiles

  @Test("Switched-off and broken Private API read differently")
  func privateAPITile() {
    #expect(HomeDashboard.privateAPITile(.notEnabled).tone == .informational)
    #expect(HomeDashboard.privateAPITile(.enabledButNotWorking).tone == .problem)
    #expect(HomeDashboard.privateAPITile(.connected).value == "Connected")
  }

  @Test("The connection tile names the method, and no server reads as a dash")
  func connectionTile() {
    #expect(HomeDashboard.connectionTile(nil).value == "-")
    // Not "Connected": Local Network connects to nothing, and the word has to fit every method.
    let lan = HomeDashboard.connectionTile(.connected(method: "Local Network"))
    #expect(lan.value == "Available")
    #expect(lan.detail == "Local Network")
    let tile = HomeDashboard.connectionTile(.reconnecting(method: "Cloudflare", detail: ""))
    #expect(tile.detail == "Cloudflare")
    #expect(tile.tone == .attention)
    // Switched off is not a fault, and the tile has to say which it is.
    let off = HomeDashboard.connectionTile(
      .unavailable(method: "Local Network", reason: "it is switched off"))
    #expect(off.detail == "Local Network: it is switched off")
  }

  // MARK: - Message flow

  private static func flow(_ totals: [Int]) -> MessageFlow {
    MessageFlow(
      days: totals.enumerated().map { index, total in
        MessageFlow.Day(start: Date(timeIntervalSince1970: Double(index) * 86_400), sent: total)
      },
      heatmap: [])
  }

  @Test("Today is compared with the same weekday a week earlier")
  func todayAgainstLastWeek() {
    // Fourteen days; today (the last) is 12 and the same weekday last week is 8.
    let flow = Self.flow([0, 0, 0, 0, 0, 0, 8, 1, 1, 1, 1, 1, 1, 12].map { $0 })
    let today = HomeDashboard.today(flow)
    #expect(today == HomeDashboard.Comparison(current: 12, previous: 8))
    #expect(today?.describe(against: "last week") == "50% more than last week")
  }

  @Test("The last seven days include today and compare with the seven before")
  func weekAgainstWeek() {
    let flow = Self.flow(Array(repeating: 2, count: 7) + Array(repeating: 1, count: 7))
    let week = HomeDashboard.lastSevenDays(flow)
    #expect(week == HomeDashboard.Comparison(current: 7, previous: 14))
    #expect(week.describe(against: "the week before") == "50% fewer than the week before")
  }

  @Test("No baseline means no sentence, not a division by zero")
  func noBaseline() {
    let comparison = HomeDashboard.Comparison(current: 5, previous: 0)
    #expect(comparison.percentChange == nil)
    #expect(comparison.describe(against: "last week") == nil)
  }

  @Test("The chart draws the range, not the extra days read for the comparison")
  func visibleDaysAreTheRange() {
    let flow = Self.flow(Array(1...14))
    #expect(HomeDashboard.FlowRange.week.daysToRead == 14)
    #expect(HomeDashboard.visibleDays(flow, range: .week).map(\.total) == Array(8...14))
    #expect(HomeDashboard.busiestDay(flow, range: .week)?.total == 14)
    #expect(HomeDashboard.busiestDay(Self.flow([0, 0]), range: .week) == nil)
  }

  // MARK: - Server history

  @Test("Counters sum, levels take the peak and readings average when minutes are folded")
  func downsampleRules() {
    let base = Date(timeIntervalSince1970: 36_000)  // on a ten-minute boundary
    let points = (0..<20).map {
      MetricPoint(minute: base.addingTimeInterval(Double($0) * 60), value: Double($0 % 10))
    }
    let summed = HomeDashboard.downsample(points, bucket: 600, rule: .sum)
    #expect(summed.map(\.value) == [45, 45])
    #expect(summed.first?.minute == base)
    #expect(HomeDashboard.downsample(points, bucket: 600, rule: .maximum).map(\.value) == [9, 9])
    #expect(HomeDashboard.downsample(points, bucket: 600, rule: .mean).map(\.value) == [4.5, 4.5])
    // A bucket no minute fell in is a gap, not a zero.
    let gappy = [points[0], MetricPoint(minute: base.addingTimeInterval(3_600), value: 1)]
    #expect(HomeDashboard.downsample(gappy, bucket: 600, rule: .sum).count == 2)
    #expect(HomeDashboard.rollup(for: .socketClients) == .maximum)
    #expect(HomeDashboard.rollup(for: .memoryMegabytes) == .mean)
  }

  @Test("Availability counts overlapping spans once and an open span up to now")
  func availabilityShare() {
    let start = Date(timeIntervalSince1970: 0)
    let now = Date(timeIntervalSince1970: 1_000)
    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    let spans = [
      AvailabilitySpan(id: 1, subject: .server, start: start, end: at(400)),
      // Overlaps the first by 100 seconds.
      AvailabilitySpan(id: 2, subject: .server, start: at(300), end: at(500)),
      // Still open.
      AvailabilitySpan(id: 3, subject: .server, start: Date(timeIntervalSince1970: 800), end: nil),
      AvailabilitySpan(id: 4, subject: .messagesHelper, start: start, end: now),
    ]
    #expect(HomeDashboard.availability(spans, subject: .server, from: start, to: now) == 0.7)
    #expect(HomeDashboard.availability(spans, subject: .faceTimeHelper, from: start, to: now) == 0)
    #expect(HomeDashboard.availability(spans, subject: .server, from: now, to: now) == nil)
  }

  @Test("The Private API tile names which helpers are up")
  func privateAPIHelpers() {
    #expect(
      HomeDashboard.privateAPITile(.connected, messages: true, faceTime: false).detail
        == "Messages only")
    #expect(
      HomeDashboard.privateAPITile(.connected, messages: true, faceTime: true).detail
        == "Messages and FaceTime")
  }

  @Test("Uptime reads in at most two units")
  func uptimeText() {
    #expect(HomeDashboard.uptime(30) == "Just started")
    #expect(!HomeDashboard.uptime(3 * 86_400 + 4 * 3_600 + 5 * 60).isEmpty)
  }

  @Test("A degraded service that measures its progress is in flight, not a problem")
  func measuredDegradedIsInFlight() {
    let rollup = HomeDashboard.rollup(
      [
        ServiceIdentifier("app.example.indexer"): .degraded(
          reason: "building the search index: 41,499 messages", progress: 0.4),
        ServiceIdentifier("app.example.proxy"): .degraded(reason: "rate limited"),
      ]
    ) { $0.rawValue }
    #expect(rollup.starting == 1)
    #expect(rollup.problems.map(\.id) == ["app.example.proxy"])
    #expect(rollup.tone == .attention)
  }

  @Test("A relative age moves once a minute and never mentions seconds")
  func relativeAgeIsToTheMinute() {
    let minute = Date(timeIntervalSince1970: 1_700_000_040)
    let now = minute.addingTimeInterval(50)
    // Same minute, different seconds: the same string.
    #expect(
      HomeDashboard.relative(minute.addingTimeInterval(5), to: now)
        == HomeDashboard.relative(minute.addingTimeInterval(45), to: now))
    #expect(!HomeDashboard.relative(minute.addingTimeInterval(5), to: now).contains("second"))
    // A minute earlier reads differently from the current minute.
    #expect(
      HomeDashboard.relative(minute.addingTimeInterval(-30), to: now)
        != HomeDashboard.relative(minute.addingTimeInterval(5), to: now))
    // And the future is not the past.
    #expect(
      HomeDashboard.relative(now.addingTimeInterval(3_600), to: now)
        != HomeDashboard.relative(now.addingTimeInterval(-3_600), to: now))
  }

  @Test("A clock reading handed to a card is dropped to the minute")
  func minuteDropsSeconds() {
    let date = Date(timeIntervalSince1970: 1_700_000_059)
    #expect(HomeDashboard.minute(date) == Date(timeIntervalSince1970: 1_700_000_040))
    // Equal within the minute, which is what lets SwiftUI skip the card.
    #expect(
      HomeDashboard.minute(date) == HomeDashboard.minute(date.addingTimeInterval(-19)))
    #expect(HomeDashboard.minute(date) != HomeDashboard.minute(date.addingTimeInterval(41)))
  }

  // MARK: - Layout

  @Test("The grid adds columns while they fit, and never more than there are cards")
  func equalHeightGridColumns() {
    func columns(_ width: CGFloat, _ items: Int) -> Int {
      EqualHeightGrid.columns(
        for: width, minimumColumnWidth: 380, spacing: 16, itemCount: items)
    }
    #expect(columns(700, 6) == 1)
    #expect(columns(776, 6) == 2)  // two 380s and one gap, exactly
    #expect(columns(1100, 6) == 2)
    #expect(columns(1100, 1) == 1)
    #expect(columns(100, 6) == 1)  // never zero, however narrow
  }
}
