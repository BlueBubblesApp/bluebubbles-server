//  HomeView
//  Status at a glance.

import BBInterfaces
import BlueBubblesServerCore
import SwiftUI

struct HomeView: View {

  @Bindable var model: AppModel
  @State private var stats: ServerInterface.Totals?
  @State private var backend: String = "—"

  private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]

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

        if model.permissions.unsatisfiedRequiredCount > 0 {
          GlassCard {
            HStack {
              Label(
                "\(model.permissions.unsatisfiedRequiredCount) required permission(s) missing",
                systemImage: "exclamationmark.triangle.fill"
              )
              .foregroundStyle(.orange)
              Spacer()
              // A button, not the words "open Permissions" — Permissions stopped
              // being a sidebar page, so telling someone to go and find it names
              // a place that no longer exists.
              Button("Open Permissions") { model.openSettings(tab: .permissions) }
            }
          }
        }
      }
      .padding(20)
    }
    .task(id: model.phase) { await load() }
  }

  /// A key path rather than a string key: a renamed count is a build error instead of an
  /// em dash on the home screen.
  private func number(_ count: KeyPath<ServerInterface.Totals, Int>) -> String {
    guard let stats else { return "—" }
    return stats[keyPath: count].formatted(.number)
  }

  private func load() async {
    guard model.phase.isRunning, let serverAdmin = model.serverAdmin else {
      stats = nil
      backend = "—"
      return
    }
    // Straight through the interfaces layer, in-process — the same objects the HTTP
    // controllers call. Each of these would have been an IPC channel.
    //
    // The counts come from the server interface, which does not need chat.db to exist.
    // The send path does, so it — and only it — stays behind the gate.
    stats = try? await serverAdmin.counts()
    guard let interfaces = await model.interfaces() else {
      backend = "—"
      return
    }
    backend =
      await interfaces.message.availableBackend() == .privateAPI
      ? "Private API" : "AppleScript"
  }
}

struct StatCard: View {
  let title: String
  let value: String

  var body: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(value).font(.title2.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.6)
      }
    }
  }
}
