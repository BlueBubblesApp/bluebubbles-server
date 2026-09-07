//  NotificationBell
//  Alerts, reachable from anywhere without leaving what you are doing.
//
//  A popover rather than a sidebar page, because a page is the wrong shape for these: an
//  alert is not a place you go, it is something that happens to you — and reading one from a
//  page means navigating away from whatever you were configuring and then finding your way
//  back. The alerts that matter most arrive WHILE you are setting something up ("Cloudflare
//  is selected but not installed"), which is exactly when you can least afford to lose your
//  place.
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
      Image(systemName: model.alerts.unreadCount > 0 ? "bell.badge.fill" : "bell")
        .symbolRenderingMode(model.alerts.unreadCount > 0 ? .palette : .monochrome)
        .foregroundStyle(
          model.alerts.unreadCount > 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary),
          AnyShapeStyle(.primary)
        )
    }
    .help(
      model.alerts.unreadCount > 0
        ? "\(model.alerts.unreadCount) unread notification\(model.alerts.unreadCount == 1 ? "" : "s")"
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
        if model.alerts.unreadCount > 0 {
          Text("\(model.alerts.unreadCount)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.red))
            .accessibilityLabel("\(model.alerts.unreadCount) unread")
        }
        Spacer()
        Button("Mark All Read") { Task { await model.alerts.markAllRead() } }
          .controlSize(.small)
          .disabled(model.alerts.unreadCount == 0)
      }
      .padding(12)

      Divider()

      if model.alerts.items.isEmpty {
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
