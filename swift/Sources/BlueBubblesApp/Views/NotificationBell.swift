//  NotificationBell
//  Alerts, reachable from anywhere without leaving what you are doing.
//
//  Notifications used to be a sidebar page. That is the wrong shape for them: an alert is not
//  a place you go, it is something that happens to you — and reading one meant navigating away
//  from whatever you were configuring and then finding your way back. Worse, the alerts that
//  matter most arrive WHILE you are setting something up ("Cloudflare is selected but not
//  installed"), which is exactly when you can least afford to lose your place.
//
//  As a popover it is glanceable, dismissible, and available from every page — and the
//  remedies an alert carries can be acted on without the page underneath changing.
//
//  See `.claude/docs/architecture.md`.

import BBDiagnostics
import SwiftUI

struct NotificationBell: View {

  @Bindable var model: AppModel
  @State private var isShowing = false

  var body: some View {
    Button {
      isShowing.toggle()
    } label: {
      // The badge is the whole point of a bell: it has to say "something needs you"
      // without being opened. An unread count of zero shows a plain bell rather than a
      // zero, because a permanent "0" trains people to stop looking.
      Image(systemName: model.unreadAlertCount > 0 ? "bell.badge.fill" : "bell")
        .symbolRenderingMode(model.unreadAlertCount > 0 ? .palette : .monochrome)
        .foregroundStyle(
          model.unreadAlertCount > 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary),
          AnyShapeStyle(.primary)
        )
    }
    .help(
      model.unreadAlertCount > 0
        ? "\(model.unreadAlertCount) unread notification\(model.unreadAlertCount == 1 ? "" : "s")"
        : "Notifications"
    )
    .popover(isPresented: $isShowing, arrowEdge: .bottom) {
      NotificationsPopover(model: model, dismiss: { isShowing = false })
        .frame(width: 420, height: 460)
    }
  }
}

/// The popover's contents: the same alert list, sized for a panel.
struct NotificationsPopover: View {

  @Bindable var model: AppModel
  let dismiss: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Notifications").font(.headline)
        // Repeats the bell's badge inside the popover. Opening the popover is exactly
        // when the badge stops being visible, and "how many of these are new" is the
        // first thing anyone wants to know on opening it.
        if model.unreadAlertCount > 0 {
          Text("\(model.unreadAlertCount)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.red))
            .accessibilityLabel("\(model.unreadAlertCount) unread")
        }
        Spacer()
        Button("Mark All Read") { Task { await model.markAlertsRead() } }
          .controlSize(.small)
          .disabled(model.unreadAlertCount == 0)
      }
      .padding(12)

      Divider()

      if model.alerts.isEmpty {
        ContentUnavailableView(
          "Nothing to report",
          systemImage: "bell.slash",
          description: Text("Alerts about things needing attention appear here.")
        )
      } else {
        // The same list the page showed, and the same actions — an alert's remedy is
        // usable from here, which is most of why the popover is worth having.
        NotificationsView(model: model, onNavigate: dismiss)
      }
    }
  }
}
