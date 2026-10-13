//  HomeCards
//  The summary cards on Home. Each one draws a value `HomeDashboard` has already decided;
//  none of them reads the server.

import BBAuth
import BBInterfaces
import Charts
import SwiftUI

// MARK: - Services

struct HomeServicesCard: View {
  @Bindable var model: AppModel
  let rollup: HomeDashboard.ServiceRollup

  var body: some View {
    HomeCard(
      "Services", symbol: "square.stack.3d.up",
      destination: ("Integrations", { model.selection = .integrations })
    ) {
      if rollup.problems.isEmpty {
        Label(rollup.headline.capitalisedFirst, systemImage: "checkmark.circle.fill")
          .foregroundStyle(rollup.tone == .good ? StatusTone.good.tint : .secondary)
          .font(.callout)
      } else {
        ForEach(rollup.problems) { problem in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: problem.line.symbol)
              .foregroundStyle(problem.tone.tint)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(problem.name).font(.callout.weight(.medium))
              Text(problem.line.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
      Spacer(minLength: 0)
      Divider()
      Text(rollup.footer)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Delivery

struct HomeDeliveryCard: View {
  @Bindable var model: AppModel
  let push: HomeDashboard.PushSummary?
  let webhooks: HomeDashboard.WebhookSummary
  /// To the minute; see `HomeDashboard.relative`.
  let now: Date

  var body: some View {
    HomeCard("Delivery", symbol: "paperplane") {
      HomeFigure(label: "Push devices", value: push.map { $0.devices.formatted() } ?? "-")
      if let recent = push?.mostRecent {
        HomeFigure(
          label: "Last active",
          value: "\(recent.name), \(HomeDashboard.relative(recent.at, to: now))")
      }
      HomeFigure(label: "Webhooks", value: webhooks.registered.formatted())
      if webhooks.failing > 0 {
        HomeFigure(
          label: "Failing", value: webhooks.failing.formatted(), tone: .attention)
      }
      HStack {
        Button("Firebase") { model.selection = .firebase }
        Button("Webhooks") { model.selection = .webhooks }
      }
      .controlSize(.small)
    }
  }
}

// MARK: - Security

struct HomeSecurityCard: View {
  @Bindable var model: AppModel
  let snapshot: AccessControlSnapshot?
  /// Passed in rather than read here, so the chart's window is the one the page decided,
  /// and to the minute (`HomeDashboard.minute`), so the card is not a new value on every
  /// body.
  let now: Date

  private var buckets: [HomeDashboard.Bucket] {
    HomeDashboard.hourly(snapshot?.failures.map(\.at) ?? [], now: now)
  }

  var body: some View {
    let buckets = buckets
    let total = buckets.reduce(0) { $0 + $1.count }
    HomeCard(
      "Security", symbol: "lock.shield",
      destination: ("Security", { model.openSettings(tab: .security) })
    ) {
      HomeFigure(
        label: "Blocked addresses",
        value: snapshot.map { $0.blocked.count.formatted() } ?? "-",
        tone: (snapshot?.blocked.isEmpty ?? true) ? nil : .attention)
      HomeFigure(
        label: "Failed sign-ins, last 24 hours",
        value: snapshot == nil ? "-" : total.formatted(),
        tone: total > 0 ? .attention : nil)
      HomeFailedSignInsChart(buckets: buckets, total: total).equatable()
    }
  }
}

/// Its own `Equatable` view, so the chart is rebuilt when the buckets move (a failure, or
/// the hour) and not whenever the card above it is re-evaluated.
private struct HomeFailedSignInsChart: View, Equatable {
  let buckets: [HomeDashboard.Bucket]
  let total: Int

  var body: some View {
    Chart(buckets) { bucket in
      BarMark(
        x: .value("Hour", bucket.start, unit: .hour),
        y: .value("Failed sign-ins", bucket.count)
      )
      .foregroundStyle(.orange.gradient)
    }
    .chartYAxis(.hidden)
    .chartXAxis {
      AxisMarks(values: .stride(by: .hour, count: 6)) {
        AxisValueLabel(format: .dateTime.hour())
      }
    }
    .chartFrame(height: 64)
    .accessibilityLabel("Failed sign-ins by hour")
    .accessibilityValue("\(total.counted("failed sign-in")) in the last 24 hours")
  }
}

// MARK: - Scheduled messages

struct HomeScheduleCard: View {
  @Bindable var model: AppModel
  let summary: HomeDashboard.ScheduleSummary?
  /// To the minute; see `HomeDashboard.relative`.
  let now: Date

  var body: some View {
    HomeCard(
      "Scheduled", symbol: "clock",
      destination: ("Scheduled", { model.selection = .scheduled })
    ) {
      HomeFigure(label: "Pending", value: summary.map { $0.pending.formatted() } ?? "-")
      HomeFigure(
        label: "Next send",
        value: summary?.nextDue.map { HomeDashboard.relative($0, to: now) } ?? "-")
      if let failed = summary?.failed, failed > 0 {
        HomeFigure(label: "Failed", value: failed.formatted(), tone: .problem)
      }
    }
  }
}

// MARK: - Library

/// What is in `chat.db`: the four totals, attachments by kind, and chats by service.
struct HomeLibraryCard: View {
  let totals: AdminInterface.Totals?
  let media: HomeDashboard.MediaBreakdown?
  let chats: ChatInterface.ChatCounts?

  private func number(_ value: Int?) -> String { value?.formatted() ?? "-" }

  var body: some View {
    HomeCard("Messages database", symbol: "tray.full") {
      Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
        GridRow {
          HomeFigure(label: "Messages", value: number(totals?.messages))
          HomeFigure(label: "Chats", value: number(totals?.chats))
        }
        GridRow {
          HomeFigure(label: "Handles", value: number(totals?.handles))
          HomeFigure(label: "Attachments", value: number(totals?.attachments))
        }
        if let media {
          Divider().gridCellColumns(2)
          GridRow {
            HomeFigure(label: "Pictures", value: media.images.formatted())
            HomeFigure(label: "Videos", value: media.videos.formatted())
          }
          GridRow {
            HomeFigure(label: "Audio", value: media.audio.formatted())
            HomeFigure(label: "Locations", value: media.locations.formatted())
          }
        }
        if let chats, !chats.breakdown.isEmpty {
          Divider().gridCellColumns(2)
          // Sorted by size so the service most chats are on reads first, and by name after
          // that so equal counts do not swap places between reads.
          let services = chats.breakdown.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
          }
          ForEach(services, id: \.key) { service, count in
            GridRow {
              HomeFigure(label: "\(service) chats", value: count.formatted())
                .gridCellColumns(2)
            }
          }
        }
      }
    }
  }
}
