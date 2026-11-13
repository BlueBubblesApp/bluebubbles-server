//  TailscaleOnThisMacSection
//  The card on the Tailscale page, and on setup's connection step, that offers Custom URL to
//  someone whose Mac already runs Tailscale of its own.
//
//  Draws nothing at all unless a signed-in Tailscale is found: most people choosing this
//  method have no other Tailscale, and a card explaining an option that does not apply to
//  them is the crowding this page cannot afford. What it says is `TailscaleHandoff`'s.
//
//  Read once when the server comes up and again on Check Again, never on a timer: the
//  answer changes when the person runs a command, and they are the one who knows when.

import SwiftUI

struct TailscaleOnThisMacSection: View {

  @Bindable var model: AppModel
  /// Whether switching goes on to show Custom URL's page: true on the Integrations screen,
  /// false in setup, which follows the selection itself.
  let opensCustomURLPage: Bool

  @State private var handoff: TailscaleHandoff = .nothing
  @State private var isChecking = false
  /// The address waiting on the confirmation. Nil when nothing is pending.
  @State private var pendingAddress: String?

  var body: some View {
    Group {
      switch handoff {
      case .nothing:
        EmptyView()
      case .publishedAt, .publishedAtSeveral, .notPublishing:
        card
      }
    }
    .task(id: model.phase.isRunning) { await look() }
    .confirmationDialog(
      "Switch to Custom URL?",
      isPresented: .isPresent($pendingAddress),
      titleVisibility: .visible
    ) {
      Button("Switch") {
        guard let address = pendingAddress else { return }
        Task {
          await model.handOffTailscaleToCustomURL(address, opensItsPage: opensCustomURLPage)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Clients are given \(pendingAddress ?? "") from now on, and this server stops "
          + "running a Tailscale node of its own. Nothing about your own Tailscale changes.")
    }
  }

  private var card: some View {
    SettingsSection("Tailscale on This Mac", subtitle: handoff.headline) {
      VStack(alignment: .leading, spacing: 12) {
        Text(handoff.body)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if case .notPublishing(_, let command) = handoff {
          CopyableValue(command)
        }
        HStack(spacing: 10) {
          ForEach(handoff.offeredAddresses, id: \.self) { address in
            Button(
              handoff.offeredAddresses.count == 1
                ? "Use Custom URL with This Address" : "Use \(address)"
            ) {
              pendingAddress = address
            }
          }
          Spacer()
          Button("Check Again") { Task { await look() } }
            .controlSize(.small)
            .disabled(isChecking)
            .help("Look again at what your own Tailscale publishes.")
        }
      }
      .padding(.vertical, 4)
    }
  }

  private func look() async {
    isChecking = true
    defer { isChecking = false }
    handoff = await model.lookForTailscaleOnThisMac()
  }
}
