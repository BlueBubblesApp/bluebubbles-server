//  HomeView
//  Status at a glance.

import BBInterfaces
import BBServiceKit
import BBSettings
import BlueBubblesServerCore
import SwiftUI

struct HomeView: View {

  @Bindable var model: AppModel
  @State private var stats: AdminInterface.Totals?
  @State private var backend: String = "-"
  @State private var connection: Connection?

  private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]

  /// How clients reach this server, as the settings store currently has it.
  ///
  /// A snapshot struct rather than three `@State` strings so the card never renders a new
  /// address beside the previous method's name: the two change together, on the same
  /// settings write, and half of one update on screen is what someone reads as the truth.
  private struct Connection: Equatable {
    /// The method's own name, from its manifest: "Cloudflare Tunnel", "Local Network".
    /// Falls back to the raw identifier, which is the honest answer for a method this
    /// build does not have installed.
    var method: String
    /// The published URL. Empty until the method has one, which is a real state and not
    /// an error: a tunnel takes a few seconds to come up.
    var address: String
    var port: Int
  }

  /// The settings whose changes this page has to notice.
  ///
  /// The address is the one that moves without anybody touching the UI: a tunnel publishes
  /// it seconds after start, and republishes it whenever it reconnects, so a card that read
  /// once at `.running` would show "not published yet" for the whole session.
  private static let connectionKeys: Set<String> = [
    Settings.serverAddress.key, Settings.connectionMethod.key, Settings.socketPort.key,
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if case .failed(let reason) = model.phase {
          GlassCard {
            VStack(alignment: .leading, spacing: 6) {
              Label("The server did not start", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
              // Selectable: the first thing anyone does with a startup error
              // is paste it into an issue.
              Text(reason)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            }
          }
        }

        LazyVGrid(columns: columns, spacing: 12) {
          StatCard(title: "Server", value: model.phase.label)
          StatCard(title: "Send path", value: backend)
          StatCard(title: "Messages", value: number(\.messages))
          StatCard(title: "Chats", value: number(\.chats))
          StatCard(title: "Handles", value: number(\.handles))
          StatCard(title: "Attachments", value: number(\.attachments))
        }

        connectionCard

        if model.permissions.unsatisfiedRequiredCount > 0 {
          GlassCard {
            HStack {
              Label(
                "\(model.permissions.unsatisfiedRequiredCount.counted("required permission")) missing",
                systemImage: "exclamationmark.triangle.fill"
              )
              .foregroundStyle(.orange)
              Spacer()
              // A button, not the words "open Permissions": Permissions is a
              // settings tab, not a sidebar page, so telling someone to go and find
              // it names a place that is not there.
              Button("Open Permissions") { model.openSettings(tab: .permissions) }
            }
          }
        }
      }
      .padding(20)
    }
    .task(id: model.phase) { await load() }
  }

  /// How clients reach this server.
  ///
  /// On Home rather than only on Guides because it is the answer to the question people
  /// open this app to ask. The Guides page and a read-only settings row are not where
  /// someone looks after starting the server.
  private var connectionCard: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text("Connection").font(.headline)
          // The method as a tag, matching how Guides tags the Private API state: it is
          // a fixed piece of vocabulary rather than a sentence, and it is the context
          // that makes the address below make sense.
          Tag(connection?.method ?? "-")
          Spacer()
          // Straight to the tab that owns the method picker, not to Settings' first tab.
          Button("Change") { model.openSettings(tab: .connection) }
            .controlSize(.small)
        }

        LabeledContent("Server URL") {
          // Blanked, not merely annotated, when nothing is listening. `server_address`
          // holds whatever the connection method last published and no one clears it, so
          // the value survives the listener being switched off, and an address next to
          // "enter this in the app" is an instruction, not a status.
          CopyableValue(
            model.apiReachability.showsAddress ? (connection?.address ?? "") : "",
            placeholder: model.apiReachability.addressPlaceholder)
        }
        LabeledContent("Local port", value: connection.map { String($0.port) } ?? "-")

        if let note = model.apiReachability.note {
          Text(note)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("This is the URL to enter in the BlueBubbles app, with your server password.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// A key path rather than a string key: a renamed count is a build error instead of an
  /// em dash on the home screen.
  private func number(_ count: KeyPath<AdminInterface.Totals, Int>) -> String {
    guard let stats else { return "-" }
    return stats[keyPath: count].formatted(.number)
  }

  private func load() async {
    guard model.phase.isRunning, let serverAdmin = model.serverAdmin else {
      stats = nil
      backend = "-"
      connection = nil
      return
    }
    // Straight through the interfaces layer, in-process: the same objects the HTTP
    // controllers call. Each of these would have been an IPC channel.
    //
    // The counts come from the server interface, which does not need chat.db to exist.
    // The send path does, so it (and only it) stays behind the gate.
    //
    // `try?` is deliberate here and nowhere else on a list screen: this is a glance
    // dashboard, and a count that could not be read renders as "-" (see `number`), which
    // is honest for a tile and does not want an error banner. A page whose CONTENT is the
    // read goes through `ScreenModel` and shows the failure.
    stats = try? await serverAdmin.counts()
    await loadConnection()
    guard let interfaces = await model.messaging.interfaces() else {
      backend = "-"
      return
    }
    backend =
      await interfaces.message.availableBackend() == .privateAPI
      ? "Private API" : "AppleScript"
    // Last, and it never returns: the address arrives after this page has already
    // rendered. Ahead of the reads above it would have deferred them forever.
    await followConnection()
  }

  private func loadConnection() async {
    guard let settings = model.settings else {
      connection = nil
      return
    }
    let method = await settings.get(Settings.connectionMethod)
    connection = Connection(
      method: IntegrationCatalog.manifest(ServiceIdentifier(method))?.name ?? method,
      address: await settings.get(Settings.serverAddress),
      port: await settings.get(Settings.socketPort)
    )
  }

  /// Re-reads the card whenever one of its settings is written.
  ///
  /// Cancelled with the enclosing `.task(id:)`: when the phase changes, or when the
  /// detail column shows another page, so a stopped server leaves nothing running.
  private func followConnection() async {
    guard let settings = model.settings else { return }
    for await change in await settings.changes() {
      guard change.intersects(Self.connectionKeys) else { continue }
      await loadConnection()
    }
  }
}
