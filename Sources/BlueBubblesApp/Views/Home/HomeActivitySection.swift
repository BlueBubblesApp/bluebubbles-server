//  HomeActivitySection
//  How messages have been moving: per day, by service, by hour of the week, through which
//  conversations, and which conversations are new.
//
//  The one part of Home whose content IS a read, so it goes through `ScreenModel` and says
//  when that read failed, where the tiles above it render `-`. It is a read of `chat.db`
//  bounded by the chosen range; see `MessageRepository+Activity.swift` for what it costs,
//  which is why the screen and the range live on `HomeModel` rather than here: a visit
//  inside `HomeModel.maximumAge` draws what the last one read. While the first read is in
//  flight the section is a `Skeleton` of its own layout, so the cards land where the
//  skeleton was rather than under a spinner.

import BBIMessage
import BBInterfaces
import Charts
import SwiftUI

/// What the section draws, read in one go so the chart and the list never describe two
/// different moments.
struct HomeActivity: Sendable, Equatable {
  let flow: MessageFlow
  let chats: [MessageRepository.ChatActivity]
  let newChats: [MessageRepository.NewChat]
  /// Contact names by address, for labelling the chats. Empty when contact access was never
  /// granted, in which case every chat is labelled by its address, as it would be anyway.
  let contactNames: [String: String]

  /// The placeholder the section draws, built once; see `HomeModel.Glance.sample`.
  @MainActor static let sample = placeholder(now: .now)

  /// What the skeleton is drawn from: a month of days with something in every one (so the
  /// comparison tiles have a baseline and a busiest day exists), a full heatmap, and five
  /// conversations in each list. Names are generic and the identifiers name nobody.
  static func placeholder(now: Date) -> HomeActivity {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    let days = (0..<30).reversed().map { back in
      MessageFlow.Day(
        start: calendar.date(byAdding: .day, value: -back, to: today) ?? today,
        sent: 8 + (back * 7) % 13,
        received: 11 + (back * 5) % 17,
        byService: ["iMessage": 15 + (back * 3) % 20, "SMS": 4 + back % 5])
    }
    let heatmap = (0..<7).map { weekday in (0..<24).map { hour in (weekday * 3 + hour) % 9 } }
    let chats = (1...5).map { index in
      MessageRepository.ChatActivity(
        chatRowID: Int64(index), guid: "any;-;conversation-\(index)",
        displayName: "Conversation", participants: [], isGroup: index.isMultiple(of: 2),
        count: 260 - index * 40)
    }
    let newChats = (1...5).map { index in
      MessageRepository.NewChat(
        chatRowID: Int64(10 + index), guid: "any;-;new-conversation-\(index)",
        displayName: "Conversation", participants: [], isGroup: index.isMultiple(of: 3),
        started: now.addingTimeInterval(-Double(index) * 86_400), count: 40 - index * 6)
    }
    return HomeActivity(
      flow: MessageFlow(days: days, heatmap: heatmap), chats: chats, newChats: newChats,
      contactNames: [:])
  }
}

struct HomeActivitySection: View {

  @Bindable var model: AppModel
  /// The page's clock reading, to the minute (`HomeDashboard.minute`), for the ages in the
  /// new-conversations card. Handed in rather than read here, so the section is the same
  /// value for a minute.
  let now: Date

  /// What re-reads the section: the range, and a new message arriving. `newMessageMinute`
  /// moves with the server's own event stream (`ServerMetrics`), so today's bar grows while
  /// the page is open without anything here keeping time, and it moves at most once a
  /// minute, so a busy server costs one read a minute rather than one a sample. Never the
  /// snapshot, which moves on every sample and would re-evaluate this section with it.
  private struct ReloadKey: Hashable {
    var range: HomeDashboard.FlowRange
    var arrived: Date?
  }

  var body: some View {
    @Bindable var home = model.home
    HomeChartSection(
      "Messages", rangeLabel: "Range", range: $home.activityRange, screen: home.activity,
      placeholder: HomeActivity.sample, subject: "message activity", model: model,
      reloadKey: ReloadKey(range: home.activityRange, arrived: model.metrics.newMessageMinute)
    ) { activity in
      content(activity)
    }
  }

  @ViewBuilder
  private func content(_ activity: HomeActivity) -> some View {
    let range = model.home.activityRange
    let flow = activity.flow
    let visible = HomeDashboard.visibleDays(flow, range: range)
    let inRange = MessageFlow(days: visible, heatmap: flow.heatmap)

    EqualHeightGrid(minimumColumnWidth: 160, spacing: 12) {
      comparisonTile(
        "Today", HomeDashboard.today(flow), baseline: "last week", detail: visible.last)
      comparisonTile(
        "Last 7 days", HomeDashboard.lastSevenDays(flow), baseline: "the week before",
        detail: nil)
      StatCard(
        title: "In \(range.title.lowercased())", value: inRange.total.formatted(),
        detail: "\(inRange.sent.formatted()) sent · \(inRange.received.formatted()) received")
      StatCard(
        title: "Busiest day",
        value: HomeDashboard.busiestDay(flow, range: range)
          .map { $0.start.formatted(.dateTime.month(.abbreviated).day()) } ?? "-",
        detail: HomeDashboard.busiestDay(flow, range: range)
          .map { $0.total.counted("message") })
    }

    EqualHeightGrid(minimumColumnWidth: 380, spacing: 16) {
      // The charts are `Equatable` and `.equatable()`, so a body re-run above them (the
      // section follows the screen and the range) rebuilds a chart only when its data moved.
      HomeCard("Per day", symbol: "chart.bar") {
        HomeFlowChart(days: visible).equatable()
        serviceBreakdown(inRange.byService)
      }
      HomeCard("Busiest conversations", symbol: "bubble.left.and.bubble.right") {
        HomeBusiestChats(chats: activity.chats, contactNames: activity.contactNames)
      }
      HomeCard("When", symbol: "calendar") {
        // The heatmap covers everything that was read, which for the week range is the
        // fortnight behind the comparison: two samples of each weekday rather than one.
        HomeHeatmap(heatmap: flow.heatmap).equatable()
      }
      HomeCard("New conversations", symbol: "person.badge.plus") {
        HomeNewChats(chats: activity.newChats, contactNames: activity.contactNames, now: now)
      }
    }
  }

  private func comparisonTile(
    _ title: String, _ comparison: HomeDashboard.Comparison?, baseline: String,
    detail day: MessageFlow.Day?
  ) -> StatCard {
    let sentence = comparison?.describe(against: baseline)
    let split = day.map { "\($0.sent.formatted()) sent · \($0.received.formatted()) received" }
    return StatCard(
      title: title,
      value: comparison.map { $0.current.formatted() } ?? "-",
      detail: sentence ?? split)
  }

  @ViewBuilder
  private func serviceBreakdown(_ services: [String: Int]) -> some View {
    let sorted = services.sorted {
      $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
    }
    if !sorted.isEmpty {
      HStack(spacing: 16) {
        ForEach(sorted, id: \.key) { service, count in
          HomeFigure(label: HomeDashboard.serviceName(service), value: count.formatted())
            .fixedSize()
        }
      }
    }
  }

  /// The read, called by `HomeModel`, whose screen this section draws.
  ///
  /// `displayNames` is a glance: a name that could not be resolved falls back to the
  /// address, which is what this shows anyway on a server without contact access. The two
  /// chat.db reads are the content and throw.
  static func read(
    model: AppModel, range: HomeDashboard.FlowRange
  ) async throws -> HomeActivity? {
    guard model.phase.isRunning, let interfaces = await model.messaging.interfaces() else {
      return nil
    }
    async let flow = interfaces.message.flow(days: range.daysToRead)
    async let chats = interfaces.message.busiestChats(days: range.days, limit: 5)
    async let newChats = interfaces.message.newChats(days: range.days, limit: 5)
    let (readFlow, readChats, readNewChats) = try await (flow, chats, newChats)
    let addresses = Array(
      Set(readChats.flatMap(\.participants) + readNewChats.flatMap(\.participants)))
    let names =
      addresses.isEmpty
      ? [:] : ((try? await interfaces.contact.displayNames(for: addresses)) ?? [:])
    return HomeActivity(
      flow: readFlow, chats: readChats, newChats: readNewChats, contactNames: names)
  }
}

/// Sent and received per day, stacked.
private struct HomeFlowChart: View, Equatable {
  let days: [MessageFlow.Day]

  var body: some View {
    let total = days.reduce(0) { $0 + $1.total }
    Chart {
      ForEach(days) { day in
        BarMark(
          x: .value("Day", day.start, unit: .day),
          y: .value("Messages", day.received)
        )
        .foregroundStyle(by: .value("Direction", "Received"))
        BarMark(
          x: .value("Day", day.start, unit: .day),
          y: .value("Messages", day.sent)
        )
        .foregroundStyle(by: .value("Direction", "Sent"))
      }
    }
    .chartForegroundStyleScale(["Received": Color.accentColor, "Sent": Color.green])
    .chartLegend(position: .top, alignment: .leading)
    .chartFrame(height: 180)
    .accessibilityLabel("Messages per day")
    .accessibilityValue("\(total.counted("message")) over \(days.count.counted("day"))")
  }
}

/// Messages by weekday and hour: when this account is busy.
private struct HomeHeatmap: View, Equatable {
  let heatmap: [[Int]]

  private struct Cell: Identifiable {
    let weekday: String
    let hour: Int
    let count: Int
    var id: String { "\(weekday)-\(hour)" }
  }

  private var cells: [Cell] {
    let symbols = Calendar.current.shortWeekdaySymbols
    // Monday first when the locale's week starts on Monday, so the grid reads the way a
    // calendar on this Mac does.
    let first = Calendar.current.firstWeekday - 1
    let order = (0..<7).map { (first + $0) % 7 }
    return order.flatMap { weekday in
      (0..<24).map { hour in
        Cell(
          weekday: symbols[weekday], hour: hour,
          count: heatmap.indices.contains(weekday) ? heatmap[weekday][hour] : 0)
      }
    }
  }

  var body: some View {
    let cells = cells
    let busiest = cells.max { $0.count < $1.count }
    Chart(cells) { cell in
      RectangleMark(
        x: .value("Hour", cell.hour),
        y: .value("Day", cell.weekday)
      )
      .foregroundStyle(by: .value("Messages", cell.count))
    }
    .chartForegroundStyleScale(range: Gradient(colors: [.accentColor.opacity(0.06), .accentColor]))
    .chartXScale(domain: 0...23)
    .chartXAxis {
      AxisMarks(values: [0, 6, 12, 18]) { value in
        AxisValueLabel {
          if let hour = value.as(Int.self) {
            Text(
              Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?
                .formatted(.dateTime.hour()) ?? "")
          }
        }
      }
    }
    .chartLegend(.hidden)
    .chartFrame(height: 180)
    .accessibilityLabel("Messages by weekday and hour")
    .accessibilityValue(
      busiest.map { $0.count > 0 ? "Busiest: \($0.weekday) at \($0.hour):00" : "No messages" }
        ?? "No messages")
  }
}

/// The five conversations with the most messages in the range.
private struct HomeBusiestChats: View {
  let chats: [MessageRepository.ChatActivity]
  let contactNames: [String: String]

  var body: some View {
    if chats.isEmpty {
      SectionEmptyText("No messages in this range.")
    } else {
      let most = chats.map(\.count).max() ?? 1
      VStack(alignment: .leading, spacing: 10) {
        ForEach(chats, id: \.chatRowID) { chat in
          let label = ConversationLabel(
            for: ChatInterface.ChatSummary(
              guid: chat.guid, displayName: chat.displayName, participants: chat.participants),
            contactNames: contactNames)
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              chatSymbol(isGroup: chat.isGroup)
              Text(label.name).lineLimit(1).truncationMode(.tail)
              Spacer(minLength: 8)
              Text(chat.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            ProgressView(value: Double(chat.count), total: Double(max(most, 1)))
              .progressViewStyle(.linear)
              .accessibilityHidden(true)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(label.name)
          .accessibilityValue(chat.count.counted("message"))
        }
      }
    }
  }
}

/// The conversations that began in the range, newest first: who this account started
/// talking to, and how much has been said since.
private struct HomeNewChats: View {
  let chats: [MessageRepository.NewChat]
  let contactNames: [String: String]
  let now: Date

  var body: some View {
    if chats.isEmpty {
      SectionEmptyText("No new conversations in this range.")
    } else {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(chats, id: \.chatRowID) { chat in
          let label = ConversationLabel(
            for: ChatInterface.ChatSummary(
              guid: chat.guid, displayName: chat.displayName, participants: chat.participants),
            contactNames: contactNames)
          let started = HomeDashboard.relative(chat.started, to: now)
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            chatSymbol(isGroup: chat.isGroup)
            VStack(alignment: .leading, spacing: 2) {
              Text(label.name).lineLimit(1).truncationMode(.tail)
              Text("Started \(started)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(chat.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
          }
          .font(.callout)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(label.name)
          .accessibilityValue("started \(started), \(chat.count.counted("message"))")
        }
      }
    }
  }
}

/// The group-or-direct mark in front of a conversation's name.
///
/// In a fixed frame: `person.3.fill` is wider than `person.fill`, and without one the names
/// in a list start at two different x positions depending on which kind of chat each row is.
@ViewBuilder
private func chatSymbol(isGroup: Bool) -> some View {
  Image(systemName: isGroup ? "person.3.fill" : "person.fill")
    .foregroundStyle(.secondary)
    .frame(width: SettingsMetrics.iconColumnWidth)
    .accessibilityHidden(true)
}
