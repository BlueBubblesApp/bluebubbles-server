//  HomeDashboard
//  What Home says about the server, decided off the view.
//
//  Home is a dashboard: every card is a summary of state some other page owns in full. The
//  summarising is where it can be wrong: a service counted as a problem when it is only
//  switched off, a failure bucketed into the wrong hour, the next scheduled send read off a
//  cancelled row. So every one of those rules is here, as a pure function, where a test can
//  pose it a question. Touching a SwiftUI `View` type from a test process traps; see
//  `Sources/BlueBubblesApp/CLAUDE.md`, "Policy lives off the view".
//
//  Anything that reads the clock takes `now` as a parameter, for the same reason
//  `BlockedClientSummary` does.

import BBAppStore
import BBEvents
import BBIMessage
import BBInterfaces
import BBServiceKit
import Foundation

enum HomeDashboard {

  // MARK: - Services

  /// Every registered service, reduced to what Home can say in one tile and one list.
  struct ServiceRollup: Equatable {

    /// A service that is meant to be running and is not.
    struct Problem: Equatable, Identifiable {
      /// The registry key, for identity only; never shown.
      let id: String
      let name: String
      let line: ServiceStatusSummary.Line
      let tone: StatusTone
    }

    var running = 0
    /// Coming up, or running and measurably working towards fully functional: a search
    /// index being built. Neither is complete and neither needs anything from the person.
    var starting = 0
    /// Switched off, waiting on a permission, or stranded behind a dependency that is off.
    /// Not a problem: a switched-off service already says so on its own page, and counting
    /// it here would put a warning on every install that does not use ngrok.
    var off = 0
    /// Worst first, then by name, so the list does not reshuffle while nothing changes.
    var problems: [Problem] = []

    var tone: StatusTone {
      if problems.contains(where: { $0.tone == .problem }) { return .problem }
      if !problems.isEmpty { return .attention }
      if running == 0 && starting == 0 { return .informational }
      return .good
    }

    /// One line for the tile.
    var headline: String {
      if !problems.isEmpty {
        return problems.count == 1
          ? "Needs attention" : "\(problems.count.counted("service")) need attention"
      }
      if starting > 0 { return "\(starting.counted("service")) starting" }
      return "\(running) running"
    }

    /// The second line of the tile: WHICH service, when it is one, so nobody has to go and
    /// find out; a count otherwise, since a tile cannot list four.
    var detail: String? {
      switch problems.count {
      case 0: nil
      case 1: problems[0].name
      default: "\(problems.count.counted("service"))"
      }
    }

    /// The card's footer: the whole population in one line, kept apart from the list of
    /// problems above it so a count cannot read as belonging to the last service listed.
    var footer: String {
      var parts = ["\(running) running"]
      if starting > 0 { parts.append("\(starting) starting") }
      if off > 0 { parts.append("\(off) switched off or waiting") }
      return parts.joined(separator: " · ")
    }
  }

  /// - Parameter name: a service's display name, from its manifest. A closure rather than the
  ///   catalogue, so a test can name services without registering any.
  static func rollup(
    _ healths: [ServiceIdentifier: ServiceHealth],
    name: (ServiceIdentifier) -> String
  ) -> ServiceRollup {
    var rollup = ServiceRollup()
    for (id, health) in healths {
      switch health {
      case .running: rollup.running += 1
      case .starting: rollup.starting += 1
      case .degraded(_, .some):
        // A fraction is the service's claim of being in flight (`ServiceHealth.degraded`),
        // and the sidebar is already listing it as a task with a bar. Listed here as a
        // problem it was two pages disagreeing, and worse: the reason carries a count that
        // moves every report, so the card's text changed inside glass for the length of
        // the build.
        rollup.starting += 1
      case .inactive: rollup.off += 1
      case .degraded, .failed, .stopped:
        // `ServiceStatusSummary` is the sentence the Integrations page shows for the same
        // state; Home saying something different about the same service would be two pages
        // disagreeing.
        guard let line = ServiceStatusSummary.line(for: health) else { continue }
        let tone: StatusTone = if case .degraded = health { .attention } else { .problem }
        rollup.problems.append(
          ServiceRollup.Problem(id: id.rawValue, name: name(id), line: line, tone: tone))
      }
    }
    rollup.problems.sort { lhs, rhs in
      if lhs.tone != rhs.tone { return lhs.tone == .problem }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    return rollup
  }

  // MARK: - Tiles

  /// A tile's value and how it reads.
  struct Tile: Equatable {
    let value: String
    var detail: String?
    let tone: StatusTone
  }

  /// The Private API tile. Three states, not two, for the reason `PrivateAPIPresence` gives:
  /// switched off and switched-on-but-broken ask opposite things of the person.
  ///
  /// The detail names which helpers are up, because there is one per app and they come and
  /// go separately: FaceTime down while every Messages route works is a real state.
  static func privateAPITile(
    _ presence: PrivateAPIPresence, messages: Bool = false, faceTime: Bool = false
  ) -> Tile {
    let helpers: String? =
      switch (messages, faceTime) {
      case (true, true): "Messages and FaceTime"
      case (true, false): "Messages only"
      case (false, true): "FaceTime only"
      case (false, false): nil
      }
    return switch presence {
    case .connected: Tile(value: "Connected", detail: helpers, tone: .good)
    case .enabledButNotWorking: Tile(value: "Not connected", tone: .problem)
    case .notEnabled: Tile(value: "Off", tone: .informational)
    }
  }

  /// "3 d 4 h", "12 min": two units at most, because a dashboard tile is read at a glance.
  static func uptime(_ seconds: TimeInterval) -> String {
    guard seconds >= 60 else { return "Just started" }
    return Duration.seconds(Int(seconds)).formatted(
      .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2))
  }

  /// The connection tile, from the same state the status strip reads, so the two never
  /// disagree. Nil when there is no server, which reads as `-`.
  static func connectionTile(_ activity: ConnectionActivity?) -> Tile {
    switch activity {
    case .none: Tile(value: "-", tone: .informational)
    // "Available", not "Connected": a tunnel connects to something, Local Network does not,
    // and what both states share is that an address is published and the listener is up.
    case .connected(let method): Tile(value: "Available", detail: method, tone: .good)
    case .reconnecting(let method, _): Tile(value: "Reconnecting", detail: method, tone: .attention)
    case .unavailable(let method, let reason):
      // The reason, not only the method: "Local Network: it is switched off" is something
      // to act on, "Not running / Local Network" only looks like a fault.
      Tile(value: "Not running", detail: "\(method): \(reason)", tone: .attention)
    case .failed(let method, _): Tile(value: "Failed", detail: method, tone: .problem)
    }
  }

  // MARK: - Attention

  /// Something the person has to act on, in the order Home stacks them.
  enum AttentionItem: Equatable, Identifiable {
    /// The server did not come up. First, because nothing else on the page is true.
    case startupFailed(reason: String)
    /// A required permission is missing, which is a start gate for whatever needs it.
    case permissionsMissing(count: Int)
    /// Unread alerts, and the title of the newest one, which is usually the one that matters.
    case unreadAlerts(count: Int, latest: String?)
    /// A release Sparkle found and chose not to interrupt with.
    case updateAvailable(version: String)

    var id: String {
      switch self {
      case .startupFailed: "startup"
      case .permissionsMissing: "permissions"
      case .unreadAlerts: "alerts"
      case .updateAvailable: "update"
      }
    }
  }

  static func attention(
    startupFailure: String?,
    missingPermissions: Int,
    unreadAlerts: Int,
    latestUnreadAlert: String?,
    availableVersion: String?
  ) -> [AttentionItem] {
    var items: [AttentionItem] = []
    if let startupFailure { items.append(.startupFailed(reason: startupFailure)) }
    if missingPermissions > 0 { items.append(.permissionsMissing(count: missingPermissions)) }
    if unreadAlerts > 0 {
      items.append(.unreadAlerts(count: unreadAlerts, latest: latestUnreadAlert))
    }
    if let availableVersion { items.append(.updateAvailable(version: availableVersion)) }
    return items
  }

  // MARK: - Time buckets

  /// `date` with its seconds dropped: the `now` a view is handed.
  ///
  /// A view's inputs decide whether SwiftUI re-evaluates it, and `.now` read inside a body
  /// is a different input every time, so nothing under it can ever be skipped. Every clock
  /// reading Home passes into a card goes through this, so a card that draws a window
  /// ending "now" is re-evaluated once a minute rather than on every sample, and the window
  /// it draws is the same to the minute either way.
  static func minute(_ date: Date) -> Date {
    Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
  }

  /// "now", "3 minutes ago", "in 2 hours": `date` relative to `now`, to the minute.
  ///
  /// Not `formatted(.relative(…))`, which measures from the real clock and says "5 seconds
  /// ago", then "10 seconds ago": a string that changes on every sample for the first
  /// minute after anything happens, and a changed string inside glass is a glass re-sample.
  /// Both ends are dropped to the minute, so the result moves once a minute and never
  /// mentions seconds.
  ///
  /// The app's one relative age, on Home and off it (the audit log, scheduled messages,
  /// webhook deliveries, registered devices), so a phrase reads the same on every page.
  /// `SharedComponentPolicyTests` refuses a relative formatter anywhere else.
  static func relative(_ date: Date, to now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    return formatter.localizedString(for: minute(date), relativeTo: minute(now))
  }

  /// A count in one bucket of time, for a bar chart.
  struct Bucket: Equatable, Identifiable {
    let start: Date
    let count: Int
    var id: Date { start }
  }

  /// Counts `dates` into the `hours` hourly buckets ending with the current hour.
  ///
  /// Every hour is present, including the empty ones, because a chart drawn only from the
  /// hours that had something in them puts a quiet night and a busy minute side by side.
  /// A date outside the window is dropped rather than clamped into the first or last bar.
  static func hourly(
    _ dates: [Date], now: Date, hours: Int = 24, calendar: Calendar = .current
  ) -> [Bucket] {
    guard hours > 0,
      let currentHour = calendar.dateInterval(of: .hour, for: now)?.start
    else { return [] }
    let starts = (0..<hours).reversed().compactMap {
      calendar.date(byAdding: .hour, value: -$0, to: currentHour)
    }
    guard let first = starts.first else { return [] }
    var counts = [Date: Int]()
    for date in dates where date >= first && date <= now {
      guard let hour = calendar.dateInterval(of: .hour, for: date)?.start else { continue }
      counts[hour, default: 0] += 1
    }
    return starts.map { Bucket(start: $0, count: counts[$0] ?? 0) }
  }

  // MARK: - Message flow

  /// How far back the message-flow card looks.
  enum FlowRange: CaseIterable, Identifiable, Hashable {
    case week, month, quarter, year

    var id: Self { self }

    var days: Int {
      switch self {
      case .week: 7
      case .month: 30
      case .quarter: 90
      case .year: 365
      }
    }

    var title: String {
      switch self {
      case .week: "7 days"
      case .month: "30 days"
      case .quarter: "90 days"
      case .year: "1 year"
      }
    }

    /// Days to READ, which is more than the days to draw for the shortest range: the "last
    /// 7 days" figure compares against the 7 before, so a week's chart still needs a
    /// fortnight of rows.
    var daysToRead: Int { max(days, 14) }
  }

  /// A figure and the one it is compared against.
  struct Comparison: Equatable {
    let current: Int
    let previous: Int

    /// Nil when there is nothing to compare against: "up infinity percent" on a quiet week
    /// is not a sentence anyone can use.
    var percentChange: Int? {
      guard previous > 0 else { return nil }
      return Int(((Double(current - previous) / Double(previous)) * 100).rounded())
    }

    /// "12% more than", "3% fewer than", "Same as", or nil when there is no baseline.
    func describe(against baseline: String) -> String? {
      guard let change = percentChange else { return nil }
      if change == 0 { return "Same as \(baseline)" }
      return change > 0
        ? "\(change)% more than \(baseline)"
        : "\(-change)% fewer than \(baseline)"
    }
  }

  /// Today against the same weekday a week earlier, which is the comparison that means
  /// something: Monday against Sunday is mostly a statement about weekends.
  static func today(_ flow: MessageFlow) -> Comparison? {
    guard let today = flow.days.last else { return nil }
    let weekAgo = flow.days.count >= 8 ? flow.days[flow.days.count - 8].total : 0
    return Comparison(current: today.total, previous: weekAgo)
  }

  /// The last seven days, today included, against the seven before them.
  static func lastSevenDays(_ flow: MessageFlow) -> Comparison {
    let recent = flow.days.suffix(7).reduce(0) { $0 + $1.total }
    let before = flow.days.dropLast(7).suffix(7).reduce(0) { $0 + $1.total }
    return Comparison(current: recent, previous: before)
  }

  /// The days the chart draws: the range, not everything that was read for the comparison.
  static func visibleDays(_ flow: MessageFlow, range: FlowRange) -> [MessageFlow.Day] {
    Array(flow.days.suffix(range.days))
  }

  /// The busiest day in the range, or nil when nothing was sent or received at all.
  static func busiestDay(_ flow: MessageFlow, range: FlowRange) -> MessageFlow.Day? {
    let days = visibleDays(flow, range: range)
    guard let busiest = days.max(by: { $0.total < $1.total }), busiest.total > 0 else {
      return nil
    }
    return busiest
  }

  /// A service name as a person reads it. `message.service` is Apple's string, and a row
  /// with none is keyed by the empty string.
  static func serviceName(_ service: String) -> String {
    service.isEmpty ? "Other" : service
  }

  // MARK: - Server history

  /// How far back the server card looks. The hour is the server's in-memory ring and needs
  /// no read; the rest come from `metric_minute`.
  enum HistoryRange: CaseIterable, Identifiable, Hashable {
    case hour, day, week, month

    var id: Self { self }

    var title: String {
      switch self {
      case .hour: "1 hour"
      case .day: "24 hours"
      case .week: "7 days"
      case .month: "30 days"
      }
    }

    var duration: TimeInterval {
      switch self {
      case .hour: 3_600
      case .day: 86_400
      case .week: 7 * 86_400
      case .month: 30 * 86_400
      }
    }

    /// The width of one point on the chart. Chosen so every range draws 60 to 180 points:
    /// thirty days of minutes is 43,200 marks, which is a slow chart of solid colour.
    var bucket: TimeInterval {
      switch self {
      case .hour: 60
      case .day: 600
      case .week: 3_600
      case .month: 4 * 3_600
      }
    }
  }

  /// How a metric's minutes combine into a wider bucket.
  enum Rollup: Equatable {
    /// A count of things that happened: requests, events, pushes.
    case sum
    /// A level: the most clients connected at once.
    case maximum
    /// A reading: memory, CPU, latency.
    case mean
  }

  static func rollup(for metric: MetricKey) -> Rollup {
    switch metric {
    case .requests, .requestErrors, .events, .newMessages, .pushDelivered, .pushFailed: .sum
    case .socketClients: .maximum
    case .averageLatencyMilliseconds, .memoryMegabytes, .cpuPercent: .mean
    }
  }

  /// Folds minutes into buckets of `width` seconds, aligned to the epoch so a bucket's
  /// boundaries do not move between reads. A bucket with no minutes in it is absent, not
  /// zero: the server was not running, and the chart should show a gap.
  static func downsample(
    _ points: [MetricPoint], bucket width: TimeInterval, rule: Rollup
  ) -> [MetricPoint] {
    guard width > 60 else { return points }
    var groups: [Date: [Double]] = [:]
    for point in points {
      let start = Date(
        timeIntervalSince1970: (point.minute.timeIntervalSince1970 / width).rounded(.down)
          * width)
      groups[start, default: []].append(point.value)
    }
    return groups.keys.sorted().map { start in
      let values = groups[start] ?? []
      let value: Double =
        switch rule {
        case .sum: values.reduce(0, +)
        case .maximum: values.max() ?? 0
        case .mean: values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
      return MetricPoint(minute: start, value: value)
    }
  }

  /// The share of `[start, now]` a subject was up, from its spans. Overlapping spans (a
  /// crash-closed span meeting the next run's) are not double-counted.
  static func availability(
    _ spans: [AvailabilitySpan], subject: AvailabilitySubject, from start: Date, to now: Date
  ) -> Double? {
    let window = now.timeIntervalSince(start)
    guard window > 0 else { return nil }
    let intervals = spans.filter { $0.subject == subject }
      .map { (max($0.start, start), min($0.end ?? now, now)) }
      .filter { $0.0 < $0.1 }
      .sorted { $0.0 < $1.0 }
    var covered: TimeInterval = 0
    var reach = start
    for (from, to) in intervals where to > reach {
      covered += to.timeIntervalSince(max(from, reach))
      reach = to
    }
    return min(1, covered / window)
  }

  // MARK: - Library

  /// Attachment totals, in the buckets `MessageRepository.mediaBucket` files them under.
  struct MediaBreakdown: Equatable {
    var images = 0
    var videos = 0
    var audio = 0
    var locations = 0
    var other = 0

    init(images: Int = 0, videos: Int = 0, audio: Int = 0, locations: Int = 0, other: Int = 0) {
      self.images = images
      self.videos = videos
      self.audio = audio
      self.locations = locations
      self.other = other
    }

    /// From the repository's keys. A key this does not know lands in `other` rather than
    /// vanishing, so the five always add up to the attachment total.
    init(counts: [String: Int]) {
      for (kind, count) in counts {
        switch kind {
        case "image": images += count
        case "video": videos += count
        case "audio": audio += count
        case "location": locations += count
        default: other += count
        }
      }
    }
  }

  // MARK: - Scheduled messages

  struct ScheduleSummary: Equatable {
    var pending = 0
    var failed = 0
    /// The soonest pending send, or nil when nothing is pending.
    var nextDue: Date?
  }

  /// Read through the declared status enum, never a string comparison: a renamed case is a
  /// compile error here rather than a tile that quietly counts nothing.
  static func schedule(_ rows: [(status: String, scheduledFor: Date)]) -> ScheduleSummary {
    var summary = ScheduleSummary()
    for row in rows {
      switch ScheduledMessageStatus(rawValue: row.status) {
      case .pending:
        summary.pending += 1
        summary.nextDue = min(summary.nextDue ?? row.scheduledFor, row.scheduledFor)
      case .failed:
        summary.failed += 1
      case .sent, .cancelled, .none:
        break
      }
    }
    return summary
  }

  // MARK: - Delivery

  struct PushSummary: Equatable {
    var devices = 0
    /// The device heard from most recently. A device that has never reported activity is
    /// never this one.
    var mostRecent: Recent?

    struct Recent: Equatable {
      let name: String
      let at: Date
    }
  }

  static func push(_ devices: [(name: String, lastActive: Date?)]) -> PushSummary {
    var summary = PushSummary(devices: devices.count)
    for device in devices {
      guard let at = device.lastActive else { continue }
      if summary.mostRecent.map({ at > $0.at }) ?? true {
        summary.mostRecent = PushSummary.Recent(name: device.name, at: at)
      }
    }
    return summary
  }

  struct WebhookSummary: Equatable {
    var registered = 0
    /// Endpoints whose LAST delivery failed. A webhook that failed once and has delivered
    /// since is not failing.
    var failing = 0

    var tone: StatusTone {
      if registered == 0 { return .informational }
      return failing > 0 ? .attention : .good
    }
  }

  /// - Parameters:
  ///   - registered: how many webhooks the table holds, or nil when that read did not land.
  ///   - deliveries: the tracker's last outcome per webhook id.
  static func webhooks(
    registered: Int?, deliveries: [Int64: WebhookDeliveryState]
  ) -> WebhookSummary {
    let failing = deliveries.values.filter { $0.outcome.isFailure }.count
    // The tracker can outlive a deleted row, so the table's count, when there is one, is
    // the ceiling on how many can be failing.
    let total = registered ?? deliveries.count
    return WebhookSummary(registered: total, failing: min(failing, total))
  }
}
