//  GuidesView
//  The "how do I…" page in the sidebar.
//
//  Deliberately NOT a browser pointed at the docs site. Every question here is about THIS
//  machine's current state (is the Private API on, which delivery routes are live, what
//  address are clients using) and a static web page cannot answer any of them. So each guide
//  reads live state and tells the user where they actually are before telling them what to do
//  next, and links out only for the parts that genuinely live elsewhere.
//
//  See `.claude/docs/architecture.md`.

import BBBuiltIns
import BBSettings
import SwiftUI

struct GuidesView: View {

  @Bindable var model: AppModel

  /// Recomputed when the page appears and when the server starts or stops, rather than held:
  /// these are one-line reads of state that changes while the app is open, and a cached
  /// answer here would confidently tell a user the Private API is off seconds after they
  /// turned it on. Nil until the first read, and again once there is no server to read from.
  @State private var status: Status?

  /// What the contacts row says under it.
  ///
  /// Off the view because the sentence is the part that has to be right: an unreadable
  /// count must not render as "0 contacts indexed", which reads as a fact about the address
  /// book rather than about this server's access to it. Four states, four sentences.
  static func contactsDetail(for indexed: Int?, enabled: Bool = true) -> String {
    // Checked FIRST, and it is the reason this gained a parameter: with the integration off
    // the count cannot be read at all, so every other branch here would describe the
    // failure rather than the switch that caused it.
    guard enabled else { return "the Contacts integration is switched off" }
    guard let indexed else { return "the contact index could not be read" }
    // Zero is a real, reportable state (the index was read and is empty) and it is what
    // this row exists to send someone to fix.
    return indexed == 0 ? "no contacts indexed yet" : "\(indexed.counted("contact")) indexed"
  }

  struct Status: Equatable {
    var address: String
    var port: Int
    var privateAPI: Bool
    var helperConnected: Bool
    var pushConfigured: Bool
    /// Nil when the count could not be READ, which is not the same as zero.
    ///
    /// A contact index this server cannot open must not render "0 contacts indexed" on the
    /// row whose whole job is diagnosing "Messages show phone numbers instead of names":
    /// a confident zero there sends someone to re-index an address book that was never the
    /// problem.
    var contactsIndexed: Int?
    /// Whether the Contacts integration is switched on. Distinct from a count of nil: one
    /// is a decision somebody made, the other is a read that did not work.
    var contactsEnabled: Bool
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 12) {
        if !model.phase.isRunning {
          ServerStoppedNotice(
            model: model, placement: .card, purpose: "see guidance for this Mac")
        }

        connectAClient
        privateAPIGuide
        notificationsGuide
        troubleshooting
        links
      }
      .padding(20)
    }
    // Keyed on the phase for the reason `View.reloads` gives: the stopped-server card above
    // carries a Start button, and a read that ran once against no server would leave the
    // address card empty for the rest of the visit.
    .task(id: model.phase.isRunning) { await reload() }
  }

  // MARK: - Guides

  private var connectAClient: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 8) {
        Text("Connect a client").font(.headline)

        if let status {
          // The actual address, not "your server address". Typing the wrong one is
          // the single most common setup failure, and the app knows the answer.
          LabeledContent("Address") {
            // Same rule as Home: the stored address outlives the listener, and this card
            // tells someone to type it into their phone.
            CopyableValue(
              model.apiReachability.showsAddress ? status.address : "",
              placeholder: model.apiReachability.addressPlaceholder)
          }
          LabeledContent("Port", value: String(status.port))
        }

        if let note = model.apiReachability.note {
          Text(note)
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text(
          """
          Open BlueBubbles on your phone, choose Manual Setup, and enter the address \
          above with your server password. If you are on the same network and have no \
          tunnel configured, use one of the local addresses from Home.
          """
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var privateAPIGuide: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Private API").font(.headline)
          Spacer()
          if let status {
            Tag(
              status.helperConnected
                ? "connected"
                : status.privateAPI ? "enabled, not connected" : "off")
          }
        }

        Text(
          """
          Adds reactions, editing and unsending, typing indicators, and group \
          management. It works by loading a small library inside Messages, which \
          macOS only permits with System Integrity Protection disabled.
          """
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        // The state that is genuinely confusing, called out rather than left for the
        // user to infer: the setting is on, so the UI offers the features, and none of
        // them work because nothing is actually injected.
        if let status, status.privateAPI, !status.helperConnected {
          Text(
            """
            Enabled but not connected. Messages needs to be restarted by the server \
            so the helper can load; check the Permissions page for SIP status \
            first, since the helper cannot load at all while SIP is on.
            """
          )
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
        }

        Button("Open Permissions") { model.openSettings(tab: .permissions) }
          .controlSize(.small)
      }
    }
  }

  private var notificationsGuide: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Notifications while the app is closed").font(.headline)
          Spacer()
          if let status { Tag(status.pushConfigured ? "set up" : "not set up") }
        }
        Text(
          """
          Optional. Without Firebase, clients still receive everything over the \
          socket while they are open, and webhooks and ntfy work regardless; only \
          delivery to a closed app needs it.
          """
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Button("Open Firebase") { model.selection = .firebase }
          .controlSize(.small)
      }
    }
  }

  private var troubleshooting: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 10) {
        Text("If something is not working").font(.headline)

        guidance(
          "Messages show phone numbers instead of names",
          "Contacts access is missing, or the address book has not been indexed yet.",
          detail: status.map {
            Self.contactsDetail(for: $0.contactsIndexed, enabled: $0.contactsEnabled)
          }
        ) { model.selection = .contacts }

        guidance(
          "A client cannot reach the server",
          "Check the address above matches what the client has, and that the "
            + "connection method on Home is connected."
        ) { model.selection = .home }

        guidance(
          "A client suddenly stopped connecting",
          "Repeated failed logins block an address automatically. Blocks expire on "
            + "their own, and can be lifted immediately."
        ) { model.openSettings(tab: .security) }

        // Opens the drawer this sentence describes. It used to send people to the Logs
        // page, so the words and the button named two different places.
        guidance(
          "Something failed and I want the details",
          "Notifications carry a diagnostic report with secrets redacted, so it is safe "
            + "to paste into an issue. The raw log is on the Logs page."
        ) { model.alerts.isDrawerPresented = true }
      }
    }
  }

  private var links: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 8) {
        Text("Documentation").font(.headline)
        // The genuinely external things: client downloads and the written guides.
        Link("BlueBubbles documentation", destination: URL(string: "https://docs.bluebubbles.app")!)
        Link("Download a client", destination: URL(string: "https://bluebubbles.app/downloads")!)
        Text("Opens in your browser.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Pieces

  @ViewBuilder
  private func guidance(
    _ title: String,
    _ body: String,
    detail: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(title).font(.subheadline.weight(.medium))
        Spacer()
        Button("Go") { action() }.controlSize(.small)
      }
      Text(body).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let detail {
        Text(detail).font(.caption2).foregroundStyle(.tertiary)
      }
    }
  }

  private func reload() async {
    guard let settings = model.settings else {
      status = nil
      return
    }
    // `try?` collapses "no server" and "the read failed" into nil, and both genuinely mean
    // "not known" here; the distinction that matters is against ZERO, which means the
    // address book was read and is empty.
    let contacts = try? await model.messaging.contacts?.count()
    let contactsEnabled =
      IntegrationCatalog.manifest(BuiltInManifests.ID.contacts)
      .map { model.integrations.isEnabled($0) } ?? true

    status = Status(
      address: await settings.get(Settings.serverAddress),
      port: await settings.get(Settings.socketPort),
      privateAPI: await settings.get(Settings.enablePrivateAPI),
      helperConnected: await model.messaging.isHelperConnected,
      pushConfigured: await model.delivery.push?.pushInterface().status().isConfigured ?? false,
      contactsIndexed: contacts,
      contactsEnabled: contactsEnabled
    )
  }
}
