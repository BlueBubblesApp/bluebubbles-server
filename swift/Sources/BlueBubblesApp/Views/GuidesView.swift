//  GuidesView
//  The "how do I…" page in the sidebar.
//
//  Deliberately NOT a browser pointed at the docs site. Every question here is about THIS
//  machine's current state — is the Private API on, which delivery routes are live, what
//  address are clients using — and a static web page cannot answer any of them. So each guide
//  reads live state and tells the user where they actually are before telling them what to do
//  next, and links out only for the parts that genuinely live elsewhere.
//
//  See `.claude/docs/architecture.md`.

import BBSettings
import SwiftUI

struct GuidesView: View {

  @Bindable var model: AppModel

  /// Recomputed when the page appears rather than held: these are one-line reads of state
  /// that changes while the app is open, and a cached answer here would confidently tell a
  /// user the Private API is off seconds after they turned it on.
  @State private var status: Status?

  /// What the contacts row says under it.
  ///
  /// Off the view because it is the sentence, not the layout, that was wrong: an unread
  /// count rendered as "0 contacts indexed", which reads as a fact about the address book
  /// rather than about this server's access to it. Three states, three sentences.
  static func contactsDetail(for indexed: Int?) -> String {
    guard let indexed else { return "the contact index could not be read" }
    // Zero is a real, reportable state — the index was read and is empty — and it is what
    // this row exists to send someone to fix.
    return indexed == 0 ? "no contacts indexed yet" : "\(indexed) contacts indexed"
  }

  struct Status: Equatable {
    var address: String
    var port: Int
    var privateAPI: Bool
    var helperConnected: Bool
    var pushConfigured: Bool
    /// Nil when the count could not be READ, which is not the same as zero.
    ///
    /// It was `Int` filled in with `(try? …) ?? 0`, so a contact index this server could
    /// not open rendered "0 contacts indexed" — on the row whose whole job is diagnosing
    /// "Messages show phone numbers instead of names". That is the one row where a
    /// confident zero sends someone to re-index an address book that was never the problem.
    var contactsIndexed: Int?
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 12) {
        if !model.phase.isRunning {
          GlassCard {
            Label(
              "Start the server to see guidance for this Mac.",
              systemImage: "info.circle"
            )
            .font(.subheadline)
          }
        }

        connectAClient
        privateAPIGuide
        notificationsGuide
        troubleshooting
        links
      }
      .padding(20)
    }
    .task { await reload() }
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
            CopyableValue(status.address, placeholder: "not published yet")
          }
          LabeledContent("Port", value: String(status.port))
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
            so the helper can load — check the Permissions page for SIP status \
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
          socket while they are open, and webhooks and ntfy work regardless — only \
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
          detail: status.map { Self.contactsDetail(for: $0.contactsIndexed) }
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

        guidance(
          "Something failed and I want the details",
          "Open the bell at the top right — notifications carry a diagnostic report "
            + "with secrets redacted, so it is safe to paste into an issue."
        ) { model.selection = .logs }
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
    guard let settings = model.settings else { return }
    // `try?` collapses "no server" and "the read failed" into nil, and both genuinely mean
    // "not known" here — the distinction that matters is against ZERO, which means the
    // address book was read and is empty.
    let contacts = try? await model.contactIndex?.count()

    status = Status(
      address: await settings.get(Settings.serverAddress),
      port: await settings.get(Settings.socketPort),
      privateAPI: await settings.get(Settings.enablePrivateAPI),
      helperConnected: await model.isHelperConnected,
      pushConfigured: await model.pushSetup?.pushInterface().status().isConfigured ?? false,
      contactsIndexed: contacts
    )
  }
}
