//  RootView
//  The split-view shell and its sidebar.
//
//  The sidebar mirrors the routes the Electron UI had, so someone moving between the two is
//  not relearning where things live. See `.claude/docs/architecture.md`.

import SwiftUI

enum Destination: String, CaseIterable, Identifiable, Hashable {
  case home = "Home"
  case devices = "Devices"
  case contacts = "Contacts"
  case scheduled = "Scheduled"
  case webhooks = "API & Webhooks"
  case integrations = "Integrations"
  /// Push setup. Named for the service rather than for "Notifications", which is already
  /// the alerts drawer below — two sidebar rows called the same thing would be worse than
  /// naming the vendor.
  case firebase = "Firebase"
  case logs = "Logs"
  /// Not a docs link — it reads live state, because every question it answers is about THIS
  /// machine.
  case guides = "Guides"
  case settings = "Settings"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .home: "house"
    case .devices: "iphone"
    case .contacts: "person.crop.circle"
    case .scheduled: "clock"
    case .webhooks: "network"
    case .integrations: "puzzlepiece.extension"
    case .firebase: "bell.badge"
    case .logs: "doc.plaintext"
    case .guides: "book"
    case .settings: "gearshape"
    }
  }
}

struct RootView: View {

  @Bindable var model: AppModel

  @State private var showingOnboarding = false

  var body: some View {
    NavigationSplitView {
      // Plain tagged rows with an OPTIONAL selection binding.
      //
      // Two separate things had to be true, which is why fixing one at a time kept
      // failing. `NavigationLink(value:)` in a split-view sidebar drives the detail
      // column itself and does NOT reliably write through a `selection:` binding — so
      // the row highlighted while `model.selection` never moved, and the detail column,
      // which switches on that value, never re-rendered. And `List(selection:)` on macOS
      // takes `Binding<SelectionValue?>`; handing it the non-optional `$model.selection`
      // compiles against another overload and silently does nothing.
      //
      // So: no link, an optional binding, and tags of the matching optional type.
      List(selection: selectionBinding) {
        // `id: \.self` is the load-bearing part.
        //
        // `Destination` is `Identifiable` with `id: String`, so
        // `ForEach(Destination.allCases)` gives every row a selection value of type
        // `String` — while the binding is `Destination?`. The types never match, so
        // SwiftUI writes nothing: the row highlights (that is the list's own visual
        // selection) and the setter is never called at all. Proven by instrumenting
        // both halves — "detail rendering" logged once, "setter called" never.
        //
        // `.tag()` does NOT override the ForEach identity. With `id: \.self` the row's
        // selection value is the `Destination` itself, which is what the binding wants.
        ForEach(Destination.allCases, id: \.self) { destination in
          Label(destination.rawValue, systemImage: destination.symbol)
            .badge(badge(for: destination) ?? 0)
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
      .safeAreaInset(edge: .bottom) { ServerStatusBar(model: model) }
    } detail: {
      // NO NavigationStack here, and that is the fix rather than a simplification.
      //
      // Wrapping the whole detail column in one broke the sidebar: a
      // `NavigationLink(value:)` in a split-view sidebar is meant to drive the detail
      // column, and with a stack in the way the stack consumed the value instead,
      // looking for a `navigationDestination` it did not have. The rows highlighted and
      // the page never changed, with no error anywhere.
      //
      // The stack belongs to the ONE page that pushes anything — Integrations — and
      // lives inside it. Everything else is a plain view, which is what the split view
      // expects.
      detail
        .navigationTitle(model.selection.rawValue)
        .toolbar {
          // Separation from the page content, as its own item.
          //
          // NOT padding on the first link, which is where this started and which
          // produced visibly uneven spacing: padding widens that item's frame, so
          // its glyph shifts right while the next glyph does not move, and the
          // documentation-to-Discord gap ends up smaller than the Discord-to-donate
          // one. A spacer item takes the room without touching how the icons
          // themselves are laid out.
          ToolbarItem(placement: .primaryAction) {
            Spacer().frame(width: 8)
          }
          // Documentation, Discord, Donate — the three places a user leaves the app
          // for. Ahead of the bell in the trailing group so the bell stays the
          // rightmost thing, where it was before these arrived: it is the only one
          // that ever changes, and a control that acquires a badge should not move
          // because three static links were added beside it.
          ToolbarItemGroup(placement: .primaryAction) {
            CommunityLinks()
          }
          // Notifications are not a place you go, they are something that happens
          // to you — so a bell you can glance at and dismiss beats a page you have
          // to navigate to and navigate back from. It also means an alert raised
          // while you are mid-task no longer costs you your place.
          ToolbarItem(placement: .primaryAction) {
            NotificationBell(model: model)
          }
        }
    }
    .sheet(isPresented: $showingOnboarding) {
      OnboardingView(model: model, isPresented: $showingOnboarding)
    }
    .task {
      // Shown once the server is up rather than immediately: the walkthrough's
      // permission step reads live status, and with no server there is nothing to read.
      if !model.hasCompletedOnboarding {
        showingOnboarding = true
      }
    }
  }

  /// Selection as SwiftUI wants it on macOS: optional, so "nothing selected" is
  /// representable.
  ///
  /// A nil is ignored rather than stored — the detail column always shows a page, and there
  /// is no empty state to fall into.
  private var selectionBinding: Binding<Destination?> {
    Binding(
      get: { model.selection },
      set: { newValue in
        guard let newValue, newValue != model.selection else { return }
        model.selection = newValue
      }
    )
  }

  /// Counts that matter at a glance. Zero renders nothing — SwiftUI hides a `0` badge,
  /// which is what we want: a permanent `0` trains people to ignore the badge entirely.
  private func badge(for destination: Destination) -> Int? {
    switch destination {
    // Permissions is a settings tab now, so its count rides on the sidebar row that can
    // actually reach it. Losing the count entirely would remove the only prompt telling
    // someone a required grant is missing.
    case .settings:
      model.permissions.unsatisfiedRequiredCount > 0
        ? model.permissions.unsatisfiedRequiredCount : nil
    default:
      nil
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch model.selection {
    case .home: HomeView(model: model)
    case .devices: DevicesView(model: model)
    case .contacts: ContactsView(model: model)
    case .scheduled: ScheduledMessagesView(model: model)
    case .webhooks: WebhooksView(model: model)
    case .integrations: IntegrationsView(model: model)
    case .firebase: FirebaseView(model: model)
    case .logs: LogsView(model: model)
    case .guides: GuidesView(model: model)
    case .settings: SettingsView(model: model)
    }
  }
}

/// The persistent server state strip at the foot of the sidebar.
///
/// Always visible, on every page. Whether the server is actually running is the one fact that
/// makes sense of everything else on screen, and hiding it on a Home tab means reading a page
/// of empty tables before realising nothing is running.
struct ServerStatusBar: View {

  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider()
      HStack {
        StatusDot(level: level, label: model.phase.label)
        Spacer()
        Button(model.phase.isRunning ? "Stop" : "Start") {
          Task {
            if model.phase.isRunning { await model.stop() } else { await model.start() }
          }
        }
        .disabled(model.phase.isBusy)
        .controlSize(.small)
      }
      if case .failed(let reason) = model.phase {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.red)
          // Truncated in the strip but selectable and complete in the tooltip: the
          // full text of a startup failure is usually the whole diagnosis.
          .lineLimit(2)
          .help(reason)
      }
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 10)
  }

  private var level: StatusDot.Level {
    switch model.phase {
    case .running: .ok
    case .starting, .waiting, .stopping: .warning
    case .failed: .bad
    case .idle: .unknown
    }
  }
}

/// The menu-bar menu. Deliberately small: status, the two things worth doing without opening
/// a window, and a way in.
struct MenuBarContent: View {

  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text("BlueBubbles — \(model.phase.label)")

    if model.alerts.unreadCount > 0 {
      Text("\(model.alerts.unreadCount) notification(s)")
    }

    Divider()

    Button("Open BlueBubbles") {
      openWindow(id: "main")
      NSApplication.shared.activate(ignoringOtherApps: true)
    }

    Button(model.phase.isRunning ? "Stop Server" : "Start Server") {
      Task {
        if model.phase.isRunning { await model.stop() } else { await model.start() }
      }
    }
    .disabled(model.phase.isBusy)

    Divider()

    Button("Quit BlueBubbles") {
      // Stopped before terminating, so chat.db and the app database close cleanly and
      // the tunnel is torn down rather than left dangling.
      Task {
        await model.stop()
        NSApplication.shared.terminate(nil)
      }
    }
    .keyboardShortcut("q")
  }
}
