//  ManagedToolSection
//  The install/update panel on an integration's page.
//
//  It exists on the page of whatever DECLARED the program, rather than on a screen of its own,
//  because that is where the question is asked: someone choosing Cloudflare wants to know
//  whether cloudflared is on this Mac, and a separate "Programs" screen would mean finding out
//  it is not only after the tunnel failed to start.
//
//  What it shows is the whole state, not just a button: which version is installed and for
//  which architecture, where the binary came from, what is available, and what the last
//  attempt said if it failed. The failure that keeps recurring in this project is a control
//  that appears to work and silently does nothing — a bare "Install" with no readout is
//  exactly that shape.
//
//  Update is offered and never taken. See `ToolManager`.

import BBServiceKit
import BBTooling
import SwiftUI

struct ManagedToolSection: View {

  let descriptor: ManagedToolDescriptor
  @Bindable var model: AppModel

  /// Which channel the pending confirmation would install. Nil when nothing is pending.
  @State private var pendingUpdate: ToolChannel?

  private var status: ToolStatus? { model.toolStatus(descriptor.id) }

  var body: some View {
    SettingsSection(
      "Required Program",
      subtitle: "\(descriptor.displayName) runs on this Mac and carries the connection.",
      trailing: AnyView(architectureTag)
    ) {
      VStack(alignment: .leading, spacing: 12) {
        summaryRow
        if let fraction = status?.downloadFraction {
          ProgressView(value: fraction)
            .progressViewStyle(.linear)
        }
        if let activity = status?.activitySummary {
          SettingsFootnote(
            text: activity,
            symbol: isFailed ? "exclamationmark.triangle" : nil,
            tone: isFailed ? .error : .neutral
          )
        }
        if let note = status?.state.note {
          // The recommended version was not there and something else was installed.
          // Said out loud rather than left to be discovered by comparing numbers.
          SettingsFootnote(text: note, symbol: "info.circle", tone: .warning)
        }
        // The recommended-version move: a real recommendation from people who tested
        // it, so it gets the emphasis and a button.
        if let update = status?.recommendedUpdateSummary {
          SettingsFootnote(text: update, symbol: "arrow.down.circle", tone: .neutral)
        }
        // And the vendor's newest, which is a weaker claim and reads as one. It sits
        // below, in secondary type, with no call to action — someone who wants it can
        // take it from the button row.
        if let latest = status?.latestUpdateSummary {
          Text(latest + " Nothing here has been tested against it.")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        SettingsDivider()
        buttons
        provenance
      }
      .padding(.vertical, 4)
    }
    // The stream is followed only while a page showing a tool is open. A download's
    // progress crosses an actor boundary on every step, and following it from a screen
    // nobody is looking at is work for nothing.
    .task { model.beginObservingTools() }
    .onDisappear { model.endObservingTools() }
    .confirmationDialog(
      pendingUpdate == .latest
        ? "Install the newest \(descriptor.displayName)?"
        : "Update \(descriptor.displayName)?",
      isPresented: Binding(
        get: { pendingUpdate != nil },
        set: { if !$0 { pendingUpdate = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(pendingUpdate == .latest ? "Install Newest" : "Update") {
        let channel = pendingUpdate ?? .recommended
        Task { await model.installTool(descriptor.id, channel: channel) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      // Stated plainly, because this is the one update in the app that can cut off the
      // person taking it — and because the answer to "is that safe" is genuinely yes:
      // the previous version stays on disk and going back needs no network.
      Text(
        pendingUpdate == .latest
          ? "This build is newer than the one BlueBubbles recommends, and has not "
            + "been tested with this server. The tunnel restarts, so connected "
            + "clients reconnect. The version you have now is kept, and Revert puts "
            + "it back without downloading anything."
          : "The tunnel restarts, so connected clients reconnect. The version you "
            + "have now is kept, and Revert puts it back without downloading "
            + "anything."
      )
    }
  }

  // MARK: - Pieces

  private var isFailed: Bool {
    if case .failed = status?.activity { return true }
    return false
  }

  private var isBusy: Bool { status?.isBusy ?? false }

  /// Says which build would be installed here, before anyone presses anything.
  ///
  /// An Intel Mac and an Apple Silicon Mac need different downloads, and a machine with no
  /// build available at all should say so rather than failing at the end of a download.
  @ViewBuilder
  private var architectureTag: some View {
    let host = ToolArchitecture.host
    let supported =
      descriptor.build(for: host) != nil
      || (host == .arm64 && descriptor.build(for: .x86_64) != nil)
    Text(supported ? host.displayName : "Not available for \(host.displayName)")
      .font(.caption)
      .padding(.horizontal, 8).padding(.vertical, 3)
      .background(
        (supported ? Color.secondary : Color.orange).opacity(0.15), in: Capsule()
      )
  }

  private var summaryRow: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: iconName)
        .foregroundStyle(iconColor)
        .font(.title3)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(status?.installedSummary ?? "Not installed.")
            .font(.body)
          if status?.isOnRecommendedVersion == true { Tag("recommended") }
        }
        if let recommendation = status?.recommendationSummary {
          Text(recommendation)
            .font(.callout)
            .foregroundStyle(status?.isOnRecommendedVersion == true ? .green : .secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(descriptor.summary)
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
    }
  }

  private var iconName: String {
    switch status?.origin ?? .missing {
    case .missing: "exclamationmark.circle"
    case .managed, .bundled, .external: "checkmark.circle.fill"
    }
  }

  private var iconColor: Color {
    (status?.origin ?? .missing) == .missing ? .orange : .green
  }

  private var buttons: some View {
    HStack(spacing: 10) {
      if status?.origin == .missing {
        // Installs the recommended version. The label says which, because "Install"
        // alone leaves someone with a number appearing afterwards that they never
        // agreed to.
        Button(status?.recommendedVersion.map { "Install \($0)" } ?? "Install") {
          Task { await model.installTool(descriptor.id) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
      } else {
        // Deliberately a confirmation rather than a one-tap update: see the dialog.
        Button(status?.recommendedUpdate != nil ? "Update" : "Reinstall") {
          pendingUpdate = .recommended
        }
        .disabled(isBusy)

        Button("Check for Updates") {
          Task { await model.checkToolForUpdate(descriptor.id) }
        }
        .disabled(isBusy)

        if status?.canRevert == true {
          // No network, no download — the whole reason the previous version is kept.
          Button("Revert") { Task { await model.revertTool(descriptor.id) } }
            .disabled(isBusy)
        }
      }

      Spacer()

      // The escape hatch for someone waiting on a fix the recommended version does not
      // have. Small, late in the row, and never the prominent choice — but present,
      // because the alternative is that they go and install it by hand outside this
      // mechanism entirely.
      if status?.latestUpdate != nil, !isBusy {
        Button("Install Newest…") { pendingUpdate = .latest }
          .controlSize(.small)
      }

      if status?.origin == .external {
        Button("Stop Using It") { Task { await model.clearToolBinary(descriptor.id) } }
          .controlSize(.small)
      } else {
        Button("Choose Existing…") { Task { await model.chooseToolBinary(descriptor.id) } }
          .controlSize(.small)
          .help("Use a copy already on this Mac, for an offline install.")
      }
    }
  }

  /// Where it comes from and what checked it — stated, because a user is being asked to let
  /// this server download and run someone else's program.
  private var provenance: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let homepage = descriptor.homepage {
        Link(homepage.host ?? homepage.absoluteString, destination: homepage)
          .font(.callout)
      }
      Text(verificationSummary)
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let checked = status?.state.lastCheckedAt {
        Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption).foregroundStyle(.tertiary)
      }
    }
  }

  private var verificationSummary: String {
    switch descriptor.signature {
    case .pinnedTeam(let team):
      "Downloads are accepted only when signed by \(team)."
    case .trustOnFirstUse:
      status?.state.pinnedTeamID.map {
        "Downloads are accepted only when signed by \($0), which signed the copy "
          + "installed here."
      } ?? "Downloads must carry a valid Apple Developer ID signature, and later updates "
        + "must be signed by whoever signed the first one."
    case .unsigned:
      "This program is not code-signed by its publisher, so downloads are checked "
        + "against the checksums published with the release."
    }
  }
}
