//  RootView
//  The split-view shell and its sidebar.
//
//  The sidebar mirrors the routes the Electron UI had, so someone moving between the two is
//  not relearning where things live. See `.claude/docs/architecture.md`.

import AppKit
import SwiftUI

/// The sidebar's pages. No raw value: the case is the identity, and the title is a label
/// that can be reworded without renaming anything hashed or navigated by.
enum Destination: CaseIterable, Identifiable, Hashable {
  case home
  case devices
  case contacts
  case scheduled
  case webhooks
  case integrations
  /// Push setup. Named for the service rather than for "Notifications", which is already
  /// the alerts drawer below: two sidebar rows called the same thing would be worse than
  /// naming the vendor.
  case firebase
  case logs
  /// Not a docs link: it reads live state, because every question it answers is about THIS
  /// machine.
  case guides
  case settings

  var id: Self { self }

  var title: String {
    switch self {
    case .home: "Home"
    case .devices: "Devices"
    case .contacts: "Contacts"
    case .scheduled: "Scheduled"
    case .webhooks: "API & Webhooks"
    case .integrations: "Integrations"
    case .firebase: "Firebase"
    case .logs: "Logs"
    case .guides: "Guides"
    case .settings: "Settings"
    }
  }

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

  /// The main window's scene id. Shared by the scene, the menu bar and the Go menu so all
  /// three open the one window rather than racing to create a second.
  static let windowID = "main"

  @Bindable var model: AppModel

  var body: some View {
    NavigationSplitView {
      // Plain tagged rows with an OPTIONAL selection binding.
      //
      // Two separate things had to be true, which is why fixing one at a time kept
      // failing. `NavigationLink(value:)` in a split-view sidebar drives the detail
      // column itself and does NOT reliably write through a `selection:` binding, so
      // the row highlighted while `model.selection` never moved, and the detail column,
      // which switches on that value, never re-rendered. And `List(selection:)` on macOS
      // takes `Binding<SelectionValue?>`; handing it the non-optional `$model.selection`
      // compiles against another overload and silently does nothing.
      //
      // So: no link, an optional binding, and tags of the matching optional type.
      List(selection: selectionBinding) {
        // `id: \.self` is load-bearing, and stays even though `Destination.ID` is `Self`
        // today and would give the same answer.
        //
        // A row's selection value comes from the ForEach IDENTITY, not from `.tag()`, and
        // the binding here is `Destination?`. When the identity was a `String`, as it
        // once was, the two types never matched and SwiftUI silently wrote nothing: the
        // row highlighted, because that is the list's own visual selection, and the setter
        // was never called. Spelling the identity out means a change to the `Identifiable`
        // conformance cannot quietly break the sidebar again.
        ForEach(Destination.allCases, id: \.self) { destination in
          Label(destination.title, systemImage: destination.symbol)
            .badge(badge(for: destination) ?? 0)
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
      // Pinned rather than a first row in the list, for the same reason the status strip
      // is: a row scrolls away and is selectable, and the brand is neither a place you can
      // go nor something that should disappear when the list is long.
      .safeAreaInset(edge: .top) { BrandHeader() }
      .safeAreaInset(edge: .bottom) {
        // Two strips, and the order matters: work in flight grows UPWARD from the server
        // row, so the Start/Stop button never moves because a download started.
        VStack(alignment: .leading, spacing: 0) {
          BackgroundActivityList(model: model)
          ServerStatusBar(model: model)
        }
      }
    } detail: {
      // NO NavigationStack here, and that is the fix rather than a simplification.
      //
      // Wrapping the whole detail column in one broke the sidebar: a
      // `NavigationLink(value:)` in a split-view sidebar is meant to drive the detail
      // column, and with a stack in the way the stack consumed the value instead,
      // looking for a `navigationDestination` it did not have. The rows highlighted and
      // the page never changed, with no error anywhere.
      //
      // The stack belongs to the ONE page that pushes anything (Integrations) and
      // lives inside it. Everything else is a plain view, which is what the split view
      // expects.
      detail
        // The product in the title, the page in the subtitle: not the other way round.
        // The window title is the one piece of branding that
        // survives hiding the sidebar, and it is also what Mission Control, the Window
        // menu and a screenshot of a bug report all show. Integrations replaces both when
        // it pushes a service page, which is correct: at that point the service IS where
        // you are.
        .navigationTitle(Branding.name)
        .navigationSubtitle(model.selection.title)
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
          // Documentation, Discord, Donate: the three places a user leaves the app
          // for. Ahead of the bell in the trailing group so the bell stays the
          // rightmost thing: it is the only one that ever changes, and a control that
          // acquires a badge should not move because three static links sit beside it.
          ToolbarItemGroup(placement: .primaryAction) {
            CommunityLinks()
          }
          // Notifications are not a place you go, they are something that happens
          // to you, so a bell you can glance at and dismiss beats a page you have
          // to navigate to and navigate back from. It also means an alert raised
          // while you are mid-task does not cost you your place.
          // Only while something is happening: a spinner that is always there is one
          // nobody looks at. Ahead of the bell for the same reason the links are: the
          // bell stays rightmost.
          ToolbarItem(placement: .primaryAction) {
            BackgroundActivityIndicator(model: model)
          }
          ToolbarItem(placement: .primaryAction) {
            NotificationBell(model: model)
          }
        }
    }
    // Adoption first, and exclusively. Two sheets cannot both present, and this one has to
    // win: `OnboardingView` reads live permission and settings state, which does not exist
    // until the server is built, and the whole point of `.migrationRequired` is that it
    // has deliberately NOT been built.
    .sheet(
      isPresented: Binding(
        get: { model.migration.isPresented },
        set: { model.migration.isPresented = $0 }
      )
    ) {
      MigrationView(model: model)
    }
    .sheet(
      isPresented: Binding(
        get: { model.onboarding.isPresented },
        set: { model.onboarding.isPresented = $0 }
      )
    ) {
      OnboardingView(model: model)
    }
    .task(id: model.phase) {
      // Once the server is RUNNING, not merely once the app has opened.
      //
      // A bare `.task` would race `model.start()`, so the walkthrough could appear over a
      // server that has not been built, and its permission step would read nothing.
      // Keying on the phase also keeps it from
      // fighting the adoption sheet: a server that has not started because an upgrade is
      // waiting is not a server anyone should be walked through configuring.
      guard model.phase.isRunning, !model.onboarding.isComplete else { return }
      model.onboarding.present()
    }
  }

  /// Selection as SwiftUI wants it on macOS: optional, so "nothing selected" is
  /// representable.
  ///
  /// A nil is ignored rather than stored: the detail column always shows a page, and there
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

  /// Counts that matter at a glance. Zero renders nothing: SwiftUI hides a `0` badge,
  /// which is what we want: a permanent `0` trains people to ignore the badge entirely.
  private func badge(for destination: Destination) -> Int? {
    switch destination {
    // Permissions is a settings tab, so its count rides on the sidebar row that can
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
        // In `.migrationRequired` the useful action is not "start": starting is exactly
        // what has been refused; it is "re-open the sheet you closed". Pressing Start
        // there would re-run the preflight and land back in the same phase, which reads
        // as a button that does nothing.
        Button(startStopTitle) {
          Task {
            switch model.phase {
            case .migrationRequired: model.migration.present()
            case .running: await model.stop()
            default: await model.start()
            }
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
      // A connection method that has GIVEN UP. Work still in progress belongs to
      // `BackgroundActivityList` above this strip; what is left here is the state a
      // running server can be in that "Running" alone would misrepresent: reachable by
      // nobody, with nothing still trying.
      if case .failed(_, let reason) = model.connectionActivity {
        HStack(spacing: 6) {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
          Text(reason)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
            .help(reason)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 10)
  }

  private var startStopTitle: String {
    switch model.phase {
    case .migrationRequired: "Set Up…"
    case .running: "Stop"
    default: "Start"
    }
  }

  private var level: StatusDot.Level {
    switch model.phase {
    case .running: .ok
    case .starting, .waiting, .stopping: .warning
    case .failed: .bad
    // Amber, not red: nothing is broken, something is waiting on the user.
    case .migrationRequired: .warning
    case .idle: .unknown
    }
  }
}

extension MenuBarContent {
  var menuStartStopTitle: String {
    switch model.phase {
    case .migrationRequired: "Finish Setup…"
    case .running: "Stop Server"
    default: "Start Server"
    }
  }
}

/// The menu-bar menu. Deliberately small: status, the two things worth doing without opening
/// a window, and a way in.
struct MenuBarContent: View {

  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text("BlueBubbles: \(model.phase.label)")

    if model.alerts.unreadCount > 0 {
      Text(model.alerts.unreadCount.counted("notification"))
    }

    Divider()

    Button("Open BlueBubbles") {
      openWindow(id: RootView.windowID)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // Same reasoning as the sidebar button: in `.migrationRequired` the server is refusing
    // to start on purpose, so offering "Start Server" from the menu bar would be a button
    // that appears broken. Opening the window is what the user needs: the sheet lives
    // there, and a headless launch never reaches this phase at all.
    Button(menuStartStopTitle) {
      Task {
        switch model.phase {
        case .migrationRequired: openWindow(id: RootView.windowID)
        case .running: await model.stop()
        default: await model.start()
        }
      }
    }
    .disabled(model.phase.isBusy)

    Divider()

    // The two things people want from a menu-bar server without opening a window: the
    // address to paste into a client, and the log when something is wrong. Both were only
    // reachable by opening the window and navigating, which is most of a menu bar's point
    // gone. The address is followed on the model (see `AddressObservation.swift`) so this
    // menu has nothing to read and nothing to wait for.
    Button("Copy Server Address") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(model.publishedAddress, forType: .string)
    }
    // Nothing published yet, or no server. Copying an empty string looks like it worked
    // and pastes nothing, which is the failure `CopyableValue` avoids the same way.
    .disabled(model.publishedAddress.isEmpty)

    Button("Open Logs") {
      openWindow(id: RootView.windowID)
      NSApplication.shared.activate(ignoringOtherApps: true)
      model.selection = .logs
    }

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
