//  HomeView
//  The server at a glance: whether it is healthy, who it is serving, and what it holds.
//
//  A dashboard, not a page of its own content: every card summarises state another page owns
//  in full, and carries the button to that page. What each summary SAYS is decided in
//  `HomeDashboard`, off the view, where it can be tested. What it has READ is `HomeModel`,
//  off the view so a visit shows what the last one read rather than reading it all again,
//  and a card whose first read is still in flight is a `Skeleton` of itself rather than a
//  spinner of another height.
//
//  Two depths, picked in the toolbar (`HomeModel.Detail`). Basic is the tiles and the
//  summary cards; Advanced adds the Messages and Server sections, which are the charts and
//  the reads behind them. A section that is not on screen has no `.reloads` task, so Basic
//  never reads `chat.db` for a chart nobody is looking at.

import BBInterfaces
import BBServiceKit
import BBSettings
import BlueBubblesServerCore
import SwiftUI

struct HomeView: View {

  @Bindable var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Cards a tile can scroll to.
  private enum Anchor: Hashable { case services }

  /// What this visit reads for; see `HomeModel.Visit`.
  private var visit: HomeModel.Visit {
    HomeModel.Visit(
      phase: model.phase,
      pushDevices: model.pushDevicesVersion,
      webhooks: model.webhooks.registrationsVersion)
  }

  var body: some View {
    @Bindable var home = model.home
    let glance = home.glance
    let placeholder = HomeModel.Glance.sample
    let rollup = self.rollup
    // To the minute, never `.now` in a card's inputs; see `HomeDashboard.minute`.
    let now = HomeDashboard.minute(model.metrics.snapshot?.at ?? .now)
    SettingsPage(maximumWidth: SettingsMetrics.maximumDashboardWidth) { proxy in
      // WHAT the server is doing while it comes up.
      //
      // On this Mac it is a couple of seconds and barely seen. On an older one, with
      // years of messages in `chat.db`, it is minutes, and what a person met there was a
      // "Starting…" that never moved, a window that then minimised itself, and setup
      // waiting behind it. The sidebar strip carries the same line; this is the one on
      // the page they are actually looking at.
      if let stage = model.startupStage {
        GlassCard {
          HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
              Text(stage.label).font(.headline)
              Text("This takes longer the first time, and on a Mac with a lot of messages.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
          }
          // One stop rather than three; the spinner alone has nothing to say.
          .accessibilityElement(children: .combine)
          .accessibilityLabel(stage.label)
        }
      }

      // Idle or stopped, not failed: a failure is the first attention item, and says more.
      if model.phase == .idle || model.phase == .migrationRequired {
        ServerStoppedNotice(model: model, placement: .card, purpose: "see what it is doing")
      }

      ForEach(attention) { item in
        HomeAttentionRow(model: model, item: item)
      }

      EqualHeightGrid(minimumColumnWidth: 160, spacing: 12) {
        StatCard(
          title: "Server", value: model.phase.label,
          detail: model.metrics.snapshot.map { "Up \(HomeDashboard.uptime($0.uptime))" },
          tone: model.phase.tone)
        tile(
          "Private API",
          HomeDashboard.privateAPITile(
            model.privateAPIPresence,
            messages: model.privateAPIState?.isMessagesHelperConnected ?? false,
            faceTime: model.privateAPIState?.isFaceTimeHelperConnected ?? false))
        tile("Connection", HomeDashboard.connectionTile(model.connectionActivity))
        StatCard(
          title: "Services", value: model.phase.isRunning ? rollup.headline : "-",
          detail: model.phase.isRunning ? rollup.detail : nil,
          tone: model.phase.isRunning ? rollup.tone : nil,
          // The tile says a service needs attention; the card below says which and why.
          action: {
            withAnimation(reduceMotion ? nil : .easeInOut) {
              proxy.scrollTo(Anchor.services, anchor: .top)
            }
          })
        StatCard(
          title: "Clients",
          value: model.metrics.snapshot.map { $0.socketClients.formatted() } ?? "-",
          detail: model.metrics.snapshot?.lastClientActivity.map {
            "Active \(HomeDashboard.relative($0, to: now))"
          })
        StatCard(
          title: "Unread alerts", value: model.alerts.unreadCount.formatted(),
          tone: model.alerts.unreadCount > 0 ? .attention : nil)
      }

      if home.detail == .advanced {
        HomeActivitySection(model: model, now: now)

        HomeServerSection(model: model)
      }

      // Two cards abreast from about 800 points, one below that. The three cards that read
      // the glance are skeletons until their own values land; the other three draw state
      // the model follows from the server's streams, which seeds within a sample of the
      // server running and renders `-` until then.
      EqualHeightGrid(minimumColumnWidth: 380, spacing: 16) {
        HomeConnectionCard(model: model)
        HomeServicesCard(model: model, rollup: rollup).id(Anchor.services)
        Skeleton(
          value: glance, placeholder: placeholder, isLoading: home.isLoading(.delivery),
          subject: "delivery"
        ) { glance in
          HomeDeliveryCard(
            model: model,
            push: glance.push,
            webhooks: HomeDashboard.webhooks(
              registered: glance.webhooksRegistered, deliveries: model.webhooks.deliveries),
            now: now)
        }
        HomeSecurityCard(model: model, snapshot: model.accessControl, now: now)
        Skeleton(
          value: glance, placeholder: placeholder, isLoading: home.isLoading(.schedule),
          subject: "scheduled messages"
        ) { glance in
          HomeScheduleCard(model: model, summary: glance.schedule, now: now)
        }
        Skeleton(
          value: glance, placeholder: placeholder, isLoading: home.isLoading(.library),
          subject: "the messages database"
        ) { glance in
          HomeLibraryCard(totals: glance.totals, media: glance.media, chats: glance.chats)
        }
      }
    }
    .toolbar {
      Picker("Detail", selection: $home.detail) {
        ForEach(HomeModel.Detail.allCases) { detail in
          Text(detail.title).tag(detail)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .help("Advanced adds the message activity and server history charts")

      // How old what the page shows is, where someone deciding whether to press Refresh
      // is already looking. A plain string to the minute (`HomeDashboard.relative`), and
      // NOT `Text(_, style: .relative)`: that is a timer that redraws once a second, and on
      // macOS 26 the toolbar it sits in is glass, so it was a glass re-render a second for
      // as long as Home was open.
      if model.phase.isRunning, let readAt = home.glanceReadAt {
        ToolbarCaption("Updated \(HomeDashboard.relative(readAt, to: now))")
      }
      Button {
        Task { await home.refresh() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Read the counts, activity and history again now")
      .disabled(!model.phase.isRunning || home.isRefreshing)
    }
    .task(id: visit) { await home.load(for: visit) }
  }

  private func tile(_ title: String, _ tile: HomeDashboard.Tile) -> StatCard {
    StatCard(title: title, value: tile.value, detail: tile.detail, tone: tile.tone)
  }

  private var rollup: HomeDashboard.ServiceRollup {
    HomeDashboard.rollup(model.serviceHealths) {
      IntegrationCatalog.manifest($0)?.name ?? $0.rawValue
    }
  }

  private var attention: [HomeDashboard.AttentionItem] {
    let failure: String? = if case .failed(let reason) = model.phase { reason } else { nil }
    return HomeDashboard.attention(
      startupFailure: failure,
      missingPermissions: model.permissions.unsatisfiedRequiredCount,
      unreadAlerts: model.alerts.unreadCount,
      latestUnreadAlert: model.alerts.items.first { $0.readAt == nil }?.title,
      availableVersion: model.updater.availableVersion)
  }
}

/// One thing the person has to act on, with the button that acts on it.
private struct HomeAttentionRow: View {
  @Bindable var model: AppModel
  let item: HomeDashboard.AttentionItem

  var body: some View {
    switch item {
    case .startupFailed(let reason):
      GlassCard {
        VStack(alignment: .leading, spacing: 6) {
          Label("The server did not start", systemImage: "xmark.octagon.fill")
            .font(.headline)
            .foregroundStyle(StatusTone.problem.tint)
          // Selectable: the first thing anyone does with a startup error
          // is paste it into an issue.
          Text(reason)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        }
      }

    case .permissionsMissing(let count):
      row(
        "\(count.counted("required permission")) missing",
        symbol: "exclamationmark.triangle.fill", colour: StatusTone.attention.tint
      ) {
        // A button, not the words "open Permissions": Permissions is a settings tab, not a
        // sidebar page, so telling someone to go and find it names a place that is not
        // there.
        Button("Open Permissions") { model.openSettings(tab: .permissions) }
      }

    case .unreadAlerts(let count, let latest):
      row(
        latest.map { "\(count.counted("unread alert")): \($0)" }
          ?? count.counted("unread alert"),
        symbol: "bell.badge.fill", colour: StatusTone.attention.tint
      ) {
        Button("Show Alerts") { model.alerts.isDrawerPresented = true }
      }

    case .updateAvailable(let version):
      // What a scheduled check found and Sparkle chose not to interrupt with; see
      // `SparkleUpdater`'s gentle reminders. The button brings Sparkle's window forward,
      // where the notes and the Skip option are, rather than installing from here.
      row(
        "BlueBubbles \(version) is available",
        symbol: "arrow.down.circle.fill", colour: .blue
      ) {
        Button("Install Update") { model.updater.checkForUpdates() }
      }
    }
  }

  private func row<Action: View>(
    _ text: String, symbol: String, colour: Color, @ViewBuilder action: () -> Action
  ) -> some View {
    GlassCard {
      HStack {
        Label(text, systemImage: symbol)
          .foregroundStyle(colour)
          .lineLimit(2)
        Spacer()
        action()
      }
    }
  }
}
