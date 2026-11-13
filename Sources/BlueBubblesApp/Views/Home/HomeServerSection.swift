//  HomeServerSection
//  What the server itself has been doing: requests, clients, events and memory over a
//  window, the traffic since it started, and when it and its helpers were up.
//
//  The last hour is the server's in-memory ring, which the model follows as
//  `MetricsModel.ring` and which moves once a minute, so the hour's sparklines are
//  rebuilt once a minute and not on every five-second sample of the live figures beside
//  them. Anything longer is `metric_minute`, read through `ScreenModel` so a failed read
//  says so, and re-read once a minute by keying on the newest finished minute in the ring:
//  the server's clock, not one of this page's. The screen and the window live on
//  `HomeModel`, with the rest of what Home has read, and while the first read is in flight
//  the charts are a `Skeleton` of themselves.
//
//  Every chart here is its own `Equatable` view under `.equatable()`, apart from the figure
//  it sits beside: the figure is live and changes on every sample, the chart's data does
//  not, and a chart is the most expensive thing on the page to lay out.

import BBAppStore
import BlueBubblesServerCore
import Charts
import SwiftUI

/// The stored history a window needs. The hour needs none of `series`; every window needs
/// the availability spans.
struct HomeServerHistory: Sendable {
  let series: [MetricKey: [MetricPoint]]
  let spans: [AvailabilitySpan]

  /// The placeholder the section draws, built once; see `HomeModel.Glance.sample`.
  @MainActor static let sample = placeholder(now: .now)

  /// What the skeleton is drawn from: a dozen points for every charted series and a span
  /// per subject covering the whole availability window, so all three figures render. On the
  /// main actor because the series list and the window are the section's own.
  @MainActor static func placeholder(now: Date) -> HomeServerHistory {
    let points = (0..<12).reversed().map { back in
      MetricPoint(minute: now.addingTimeInterval(-Double(back) * 300), value: Double(3 + back % 5))
    }
    let series = Dictionary(uniqueKeysWithValues: HomeServerSection.charted.map { ($0, points) })
    let start = now.addingTimeInterval(-HomeServerSection.availabilityWindow)
    let spans = AvailabilitySubject.allCases.enumerated().map { index, subject in
      AvailabilitySpan(id: Int64(index + 1), subject: subject, start: start, end: nil)
    }
    return HomeServerHistory(series: series, spans: spans)
  }
}

struct HomeServerSection: View {

  @Bindable var model: AppModel

  /// The series the charts draw.
  static let charted: [MetricKey] = [
    .requests, .requestErrors, .socketClients, .events, .memoryMegabytes, .cpuPercent,
  ]

  /// How far back the availability timeline looks, whatever the chart window is.
  static let availabilityWindow: TimeInterval = 7 * 86_400

  private struct ReloadKey: Hashable {
    var range: HomeDashboard.HistoryRange
    /// Moves once a minute, when the server finishes one.
    var minute: Date?
  }

  var body: some View {
    @Bindable var home = model.home
    let screen = home.serverHistory
    // To the minute, never `.now` in a card's inputs; see `HomeDashboard.minute`.
    let now = HomeDashboard.minute(model.metrics.snapshot?.at ?? .now)
    let placeholder = HomeServerHistory.sample
    // The minute moves on the server's clock, so a visit more than a minute after the last
    // read reads again whatever the age: `metric_minute` is cheap, and for the hour window
    // (the default) the read is the availability spans alone.
    HomeChartSection(
      "Server", rangeLabel: "Window", range: $home.historyRange, screen: screen,
      placeholder: placeholder, subject: "server history", model: model,
      reloadKey: ReloadKey(range: home.historyRange, minute: model.metrics.ring.last?.start)
    ) { history in
      charts(history)
    } footer: {
      // The live figures still draw from the snapshot when the read failed.
      EqualHeightGrid(minimumColumnWidth: 380, spacing: 16) {
        // The traffic card draws the snapshot the model follows, not a read of this
        // section's, so it is never a skeleton.
        HomeTrafficCard(snapshot: model.metrics.snapshot)
        Skeleton(
          value: screen.state.value?.spans ?? [], placeholder: placeholder.spans,
          isLoading: screen.state.isLoading, subject: "availability"
        ) { spans in
          HomeAvailabilityCard(spans: spans, now: now, window: Self.availabilityWindow)
            .equatable()
        }
      }
    }
  }

  @ViewBuilder
  private func charts(_ history: HomeServerHistory) -> some View {
    let range = model.home.historyRange
    EqualHeightGrid(minimumColumnWidth: 240, spacing: 12) {
      HomeSparkCard(
        title: "Requests", unit: "per \(Self.bucketName(range))",
        points: series(.requests, history, range),
        overlay: series(.requestErrors, history, range),
        current: model.metrics.snapshot.map { $0.requests.formatted() + " since start" })
      HomeSparkCard(
        title: "Connected clients", unit: "most at once",
        points: series(.socketClients, history, range), style: .area,
        current: model.metrics.snapshot.map { $0.socketClients.counted("client") + " now" })
      HomeSparkCard(
        title: "Events", unit: "per \(Self.bucketName(range))",
        points: series(.events, history, range),
        current: model.metrics.snapshot.map { $0.eventsDispatched.formatted() + " since start" })
      // The last finished minute, not the live sample. Memory and CPU move on every sample,
      // and a figure that changes every five seconds inside a glass card is a glass
      // re-sample every five seconds: measured at about 200 MB of graphics memory a time,
      // container or not. The other three figures change only when something happened.
      HomeSparkCard(
        title: "Memory", unit: "MB",
        points: series(.memoryMegabytes, history, range), style: .line,
        current: model.metrics.ring.last.map(Self.memoryAndCPU))
    }
  }

  /// A series for the window: the in-memory ring for the hour, the store for the rest,
  /// folded to the window's bucket either way.
  private func series(
    _ metric: MetricKey, _ history: HomeServerHistory, _ range: HomeDashboard.HistoryRange
  ) -> [MetricPoint] {
    let points: [MetricPoint] =
      range == .hour
      ? model.metrics.ring.compactMap { minute in
        minute.values[metric].map { MetricPoint(minute: minute.start, value: $0) }
      }
      : history.series[metric] ?? []
    return HomeDashboard.downsample(
      points, bucket: range.bucket, rule: HomeDashboard.rollup(for: metric))
  }

  private static func bucketName(_ range: HomeDashboard.HistoryRange) -> String {
    switch range {
    case .hour: "minute"
    case .day: "10 minutes"
    case .week: "hour"
    case .month: "4 hours"
    }
  }

  private static func memoryAndCPU(_ minute: ServerMetrics.Minute) -> String {
    let memory = minute.values[.memoryMegabytes].map {
      ByteCountFormatter.string(fromByteCount: Int64($0 * 1_048_576), countStyle: .memory)
    }
    let cpu = minute.values[.cpuPercent].map { "\(Int($0.rounded()))% CPU" }
    return [memory, cpu].compactMap { $0 }.joined(separator: " · ")
  }

  /// The read, called by `HomeModel`, whose screen this section draws.
  static func read(
    model: AppModel, range: HomeDashboard.HistoryRange
  ) async throws -> HomeServerHistory? {
    guard model.phase.isRunning, let metrics = model.monitoring.metrics else { return nil }
    let now = Date()
    let spans = try await metrics.availability(since: now.addingTimeInterval(-availabilityWindow))
    guard range != .hour else { return HomeServerHistory(series: [:], spans: spans) }
    var series: [MetricKey: [MetricPoint]] = [:]
    let since = now.addingTimeInterval(-range.duration)
    for metric in charted {
      series[metric] = try await metrics.history(metric, since: since)
    }
    return HomeServerHistory(series: series, spans: spans)
  }
}

/// One small chart: a name, the figure now, and the shape of the window.
///
/// The figure is live and the chart is not, so the chart is its own view (`HomeSparkChart`)
/// and only the two `Text`s here are re-evaluated on a sample.
private struct HomeSparkCard: View {
  let title: String
  let unit: String
  let points: [MetricPoint]
  var overlay: [MetricPoint] = []
  var style: HomeSparkChart.Style = .bars
  let current: String?

  var body: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text(title).font(.caption).foregroundStyle(.secondary)
          Spacer()
          Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
        Text(current ?? "-").font(.headline).monospacedDigit().lineLimit(1)
        HomeSparkChart(title: title, points: points, overlay: overlay, style: style)
          .equatable()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(title)
      .accessibilityValue(current ?? "No data")
    }
  }
}

private struct HomeSparkChart: View, Equatable {
  enum Style { case bars, area, line }

  let title: String
  let points: [MetricPoint]
  let overlay: [MetricPoint]
  let style: Style

  var body: some View {
    Chart {
      ForEach(points) { point in
        switch style {
        case .bars:
          BarMark(x: .value("Time", point.minute), y: .value(title, point.value))
            .foregroundStyle(Color.accentColor.gradient)
        case .area:
          AreaMark(x: .value("Time", point.minute), y: .value(title, point.value))
            .foregroundStyle(Color.accentColor.opacity(0.35).gradient)
            .interpolationMethod(.stepEnd)
        case .line:
          LineMark(x: .value("Time", point.minute), y: .value(title, point.value))
            .foregroundStyle(Color.accentColor)
        }
      }
      ForEach(overlay.filter { $0.value > 0 }) { point in
        BarMark(x: .value("Time", point.minute), y: .value("Errors", point.value))
          .foregroundStyle(StatusTone.problem.tint)
      }
    }
    .chartXAxis(.hidden)
    .chartYAxis {
      AxisMarks(position: .trailing, values: .automatic(desiredCount: 2))
    }
    .chartFrame(height: 70)
    .accessibilityHidden(true)
  }
}

/// Totals since the server started, and where the requests went.
private struct HomeTrafficCard: View {
  let snapshot: ServerMetrics.Snapshot?

  var body: some View {
    HomeCard("Since start", symbol: "arrow.left.arrow.right") {
      if let snapshot {
        HomeFigure(label: "Requests", value: snapshot.requests.formatted())
        HomeFigure(
          label: "Failed",
          value: snapshot.requests > 0
            ? "\(snapshot.requestErrors.formatted()) "
              + "(\((Double(snapshot.requestErrors) / Double(snapshot.requests)).formatted(.percent.precision(.fractionLength(0...1)))))"
            : "0",
          tone: snapshot.requestErrors > 0 ? .attention : nil)
        HomeFigure(
          label: "Average response",
          value: snapshot.averageLatencyMilliseconds.map { "\(Int($0.rounded())) ms" } ?? "-")
        HomeFigure(label: "New messages", value: snapshot.newMessages.formatted())
        HomeFigure(label: "Socket events sent", value: snapshot.socketEventsSent.formatted())
        HomeFigure(
          label: "Push delivered", value: snapshot.pushDelivered.formatted())
        if snapshot.pushFailed > 0 {
          HomeFigure(
            label: "Push failed",
            value: snapshot.pushFailed.formatted()
              + " (\(snapshot.pushExpired.formatted()) expired)",
            tone: .attention)
        }
        if !snapshot.busiestRoutes.isEmpty {
          Divider()
          Text("Busiest routes").font(.caption).foregroundStyle(.secondary)
          ForEach(snapshot.busiestRoutes, id: \.template) { route in
            HomeFigure(label: route.template, value: route.requests.formatted())
              .font(.system(.caption, design: .monospaced))
          }
        }
      } else {
        SectionEmptyText("Nothing counted yet.")
      }
    }
  }
}

/// When the server and each helper were up, over the last week. `Equatable` so it is
/// rebuilt when the spans or the minute move, and not on every sample.
private struct HomeAvailabilityCard: View, Equatable {
  let spans: [AvailabilitySpan]
  let now: Date
  let window: TimeInterval

  private static let subjects: [(AvailabilitySubject, String)] = [
    (.server, "Server"), (.messagesHelper, "Messages helper"), (.faceTimeHelper, "FaceTime helper"),
  ]

  var body: some View {
    let start = now.addingTimeInterval(-window)
    HomeCard("Availability, last 7 days", symbol: "waveform.path.ecg") {
      Chart {
        ForEach(spans) { span in
          if let name = Self.subjects.first(where: { $0.0 == span.subject })?.1 {
            RectangleMark(
              xStart: .value("From", max(span.start, start)),
              xEnd: .value("To", min(span.end ?? now, now)),
              y: .value("What", name),
              height: .ratio(0.6)
            )
            .foregroundStyle(Color.green.gradient)
          }
        }
      }
      .chartXScale(domain: start...now)
      .chartYScale(domain: Self.subjects.map(\.1))
      .chartXAxis {
        AxisMarks(values: .stride(by: .day)) {
          AxisValueLabel(format: .dateTime.weekday(.abbreviated))
        }
      }
      .chartFrame(height: 110)
      .accessibilityHidden(true)

      ForEach(Self.subjects, id: \.0) { subject, name in
        let share = HomeDashboard.availability(spans, subject: subject, from: start, to: now)
        HomeFigure(
          label: name,
          value: share.map { $0.formatted(.percent.precision(.fractionLength(0...1))) } ?? "-")
      }
    }
  }
}
