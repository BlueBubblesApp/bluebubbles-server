//  NotificationsView
//  The notifications drawer, with expandable diagnostics.
//
//  An alert carries structured diagnostics rather than a string, and Copy Diagnostic Report
//  produces something a maintainer can actually read — with secrets redacted, so pasting it
//  into an issue is safe.

import AppKit
import BBCore
import BBDiagnostics
import SwiftUI

struct NotificationsView: View {

  @Bindable var model: AppModel
  /// Called when an action navigates somewhere. The popover has to close, or the page it
  /// just sent you to is hidden behind it.
  var onNavigate: (() -> Void)?
  @State private var expanded: Set<UUID> = []

  var body: some View {
    Group {
      if model.alerts.isEmpty {
        ContentUnavailableView(
          "Nothing to report",
          systemImage: "bell.slash",
          description: Text("Alerts about things needing attention appear here.")
        )
      } else {
        list
      }
    }
  }

  private var list: some View {
    ScrollView {
      VStack(spacing: 10) {
        ForEach(model.alerts) { alert in
          row(for: alert)
        }
      }
      .padding(20)
    }
  }

  /// One alert.
  ///
  /// Read and unread have to be separable at a glance, because the list mixes them: the
  /// drawer keeps history, so an alert dealt with last Tuesday sits directly above one that
  /// arrived while the popover was closed. Three signals carry it, none of them alone:
  ///
  ///   * a dot in the leading gutter — the mark Mail and Podcasts use, and the one signal
  ///     that survives at thumbnail size,
  ///   * text that steps down a level in the hierarchy once read, so a handled alert
  ///     recedes without becoming unreadable,
  ///   * a faint tint on the card's glass while unread, which is what makes a block of new
  ///     items read as a group rather than as a run of individually marked rows.
  ///
  /// Colour is never the only channel — the dot's PRESENCE is the signal, its hue only
  /// echoes the severity icon beside it. The gutter is reserved whether or not the dot is
  /// drawn, so marking everything read does not reflow the list under the pointer.
  private func row(for alert: UserAlert) -> some View {
    let isUnread = alert.readAt == nil

    return GlassCard(tint: isUnread ? colour(alert.severity).opacity(0.10) : nil) {
      HStack(alignment: .top, spacing: 10) {
        readToggle(for: alert, isUnread: isUnread)

        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol(alert.severity))
              .foregroundStyle(colour(alert.severity))
              .opacity(isUnread ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
              Text(alert.title).font(.headline)
                .foregroundStyle(isUnread ? .primary : .secondary)
              Text(alert.body).font(.subheadline)
                .foregroundStyle(isUnread ? .secondary : .tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
              Text(
                alert.lastOccurredAt.formatted(
                  date: .abbreviated, time: .shortened
                )
              )
              .font(.caption).foregroundStyle(.secondary)
              // Coalesced rather than repeated: a flapping proxy is
              // one row reading "47 times", not 47 rows.
              if alert.occurrenceCount > 1 {
                Text("×\(alert.occurrenceCount)")
                  .font(.caption.weight(.semibold))
              }
            }
          }

          // The remedy, offered where the problem is reported.
          //
          // Two call sites populate `AlertAction` — a blocked client carries
          // `.unblock(address:)`, a failing webhook carries `.openSettings`.
          // Rendering them here is what makes those remedies reachable: a
          // user locked out by the rate limiter would otherwise have to find
          // the Security page themselves.
          //
          // These keep full strength on a read alert. Read means "you have seen
          // this", not "this is over" — the blocked client is still blocked, and
          // dimming the button that unblocks it would be dimming the one thing on
          // the row that still matters.
          if !alert.actions.isEmpty {
            HStack(spacing: 8) {
              ForEach(Array(alert.actions.enumerated()), id: \.offset) {
                _, action in
                Button(Self.label(for: action)) {
                  Task { await perform(action, on: alert) }
                }
                .controlSize(.small)
              }
            }
          }

          if alert.diagnostics != nil {
            DisclosureGroup(
              isExpanded: Binding(
                get: { expanded.contains(alert.id) },
                set: { isOpen in
                  if isOpen { expanded.insert(alert.id) } else { expanded.remove(alert.id) }
                }
              )
            ) {
              diagnostics(for: alert)
            } label: {
              Text("Details").font(.caption)
            }
          }
        }
      }
    }
    // Neither the dot nor the tint says anything out loud, so the row does.
    .accessibilityElement(children: .contain)
    .accessibilityLabel(isUnread ? "Unread alert" : "Alert")
  }

  /// The unread dot, which is also the control that clears it.
  ///
  /// Clicking the dot is the whole gesture — the same one Mail puts on a message row —
  /// rather than a "Mark Read" button competing for space with the alert's actual remedy,
  /// and rather than a tap target covering the entire card, which would sit under the
  /// Unblock and Retry buttons and turn every near-miss into a silent state change.
  ///
  /// A read row keeps a hollow ring in place of the filled dot instead of going empty. That
  /// is the affordance: something is drawn there, so there is something to click, and the
  /// gutter stays the same width in both states.
  private func readToggle(for alert: UserAlert, isUnread: Bool) -> some View {
    Button {
      Task { await model.setAlertRead(alert.id, isUnread) }
    } label: {
      Circle()
        .fill(isUnread ? AnyShapeStyle(colour(alert.severity)) : AnyShapeStyle(.clear))
        .overlay(
          Circle().strokeBorder(.tertiary, lineWidth: isUnread ? 0 : 1)
        )
        .frame(width: 8, height: 8)
        // A 8pt dot is not a mouse target. The shape is what gets hit, so it is grown
        // to something a person can land on without the dot itself changing size.
        .frame(width: 22, height: 22)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    // Pulls the enlarged hit area back so the DOT — not the padding around it — lines up
    // with the cap-height of the title beside it. An alert with three lines of body would
    // otherwise float its dot somewhere in the middle of the paragraph.
    .padding(.top, -3)
    .padding(.leading, -7)
    .help(isUnread ? "Mark as read" : "Mark as unread")
    .accessibilityLabel(isUnread ? "Mark as read" : "Mark as unread")
  }

  /// What the button says. Phrased as the ACTION, not the subject — "Unblock 1.2.3.4"
  /// rather than "Security", so the button is readable without re-reading the alert.
  private static func label(for action: AlertAction) -> String {
    switch action {
    case .openSettings(let section): "Open \(section.capitalized)"
    case .openLogs: "View Logs"
    case .restartServer: "Restart Server"
    case .retry(let service): "Retry \(service)"
    case .openURL: "Open Link"
    case .relaunch: "Relaunch"
    case .unblock(let address): "Unblock \(address)"
    case .installTool(let id): "Install \(id)"
    }
  }

  /// Carries out an alert's remedy.
  ///
  /// Deliberately exhaustive over `AlertAction` with no `default`: adding a case should
  /// fail to compile here rather than render a button that does nothing, which is the
  /// failure mode this whole file is fixing.
  private func perform(_ action: AlertAction, on alert: UserAlert) async {
    // Acting on an alert is the strongest possible statement that it has been seen, so it
    // does not also need clicking. This is most of why the toggle rarely has to be touched:
    // the alerts carrying a remedy mark themselves off as you work through them.
    await model.setAlertRead(alert.id, true)

    switch action {
    case .openSettings(let section):
      let route =
        AlertActionRouting.route(forSection: section)
        ?? AlertActionRouting.Route(destination: .settings)
      model.selection = route.destination
      if let tab = route.settingsTab { model.settingsTab = tab }
      onNavigate?()

    case .openLogs:
      model.selection = .logs
      onNavigate?()

    case .retry(let service):
      await model.restartService(named: service)

    case .openURL(let url):
      NSWorkspace.shared.open(url)

    case .relaunch:
      model.relaunch()

    case .restartServer:
      await model.restart()

    case .unblock(let address):
      await model.unblock(address: address)

    case .installTool(let id):
      // To the page that offers the install, rather than installing from here. A
      // notification is where someone finds out; downloading 38 MB because they tapped
      // a button on a notice is not what that button should mean.
      guard let manifest = IntegrationCatalog.manifestDeclaring(tool: id) else { return }
      model.selection = .integrations
      model.detailPath = [manifest.id]
      onNavigate?()
    }
  }

  @ViewBuilder
  private func diagnostics(for alert: UserAlert) -> some View {
    if let report = alert.diagnostics?.redactedReport() {
      VStack(alignment: .leading, spacing: 6) {
        Text(report)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)

        Button("Copy Diagnostic Report") {
          // The REDACTED report, always. This button exists so people paste it
          // into public issues, and the unredacted form carries the server
          // password and tunnel tokens.
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(report, forType: .string)
        }
        .controlSize(.small)
      }
      .padding(.top, 4)
    }
  }

  private func symbol(_ severity: Severity) -> String {
    switch severity {
    case .critical: "xmark.octagon.fill"
    case .error: "exclamationmark.triangle.fill"
    case .warning: "exclamationmark.circle.fill"
    case .success: "checkmark.circle.fill"
    case .info: "info.circle.fill"
    }
  }

  private func colour(_ severity: Severity) -> Color {
    switch severity {
    case .critical, .error: .red
    case .warning: .orange
    case .success: .green
    case .info: .secondary
    }
  }
}
