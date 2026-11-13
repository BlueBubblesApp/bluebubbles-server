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
//  that appears to work and silently does nothing: a bare "Install" with no readout is
//  exactly that shape.
//
//  Update is offered and never taken. See `ToolManager`.
//
//  **Nothing is drawn until there is a status to draw it from.** The panel used to fall back
//  to "Not installed." and the Reinstall row while the server was still starting, and every
//  button in that row returned at once for want of a status. On a slow Mac that read as the
//  program missing and Check Again and Choose Existing doing nothing. Until the status
//  arrives this is a `ServerStoppedNotice`. Which buttons a status gets is
//  `ToolStatus.buttons`, decided off the view.

import BBServiceKit
import BBTooling
import SwiftUI

struct ManagedToolSection: View {

  let descriptor: ManagedToolDescriptor
  @Bindable var model: AppModel

  var body: some View {
    if let status = model.toolStatus(descriptor.id) {
      ManagedToolPanel(descriptor: descriptor, status: status, model: model)
    } else {
      ServerStoppedNotice(
        model: model, placement: .section(title: "Required Program"),
        purpose: "see whether \(descriptor.displayName) is installed")
    }
  }
}

/// The panel itself, for a status that has arrived.
private struct ManagedToolPanel: View {

  let descriptor: ManagedToolDescriptor
  let status: ToolStatus
  @Bindable var model: AppModel

  /// Which channel the pending confirmation would install. Nil when nothing is pending.
  @State private var pendingUpdate: ToolChannel?
  /// A program the person picked that ran but would not say which version it is. Held for
  /// the confirmation below rather than adopted quietly.
  @State private var unidentifiedChoice: String?

  var body: some View {
    SettingsSection(
      "Required Program",
      subtitle: "\(descriptor.displayName) runs on this Mac and carries the connection."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        summaryRow
        if let fraction = status.downloadFraction {
          ProgressView(value: fraction)
            .progressViewStyle(.linear)
            // Named, because a determinate bar with no label is announced as a bare
            // percentage, and this page can show one per tool, so "62 percent" on its
            // own does not say which download it belongs to.
            .accessibilityLabel("Downloading \(descriptor.displayName)")
            .accessibilityValue("\(Int(fraction * 100)) percent")
        }
        if let activity = status.activitySummary {
          SettingsFootnote(
            text: activity,
            symbol: isFailed ? "exclamationmark.triangle" : nil,
            tone: isFailed ? .problem : .informational
          )
        }
        // What is on this Mac that we did not install. Nothing when the copy in use IS
        // that copy, which the summary above has already named.
        if let copy = status.copyOnThisMacSummary {
          SettingsFootnote(
            text: copy,
            symbol: "externaldrive",
            tone: isCopyRefused ? .attention : .informational
          )
        }
        if let note = status.state.note {
          // The recommended version was not there and something else was installed.
          // Said out loud rather than left to be discovered by comparing numbers.
          SettingsFootnote(text: note, symbol: "info.circle", tone: .attention)
        }
        // The recommended-version move: a real recommendation from people who tested
        // it, so it gets the emphasis and a button.
        if let update = status.recommendedUpdateSummary {
          SettingsFootnote(text: update, symbol: "arrow.down.circle", tone: .informational)
        }
        // And the vendor's newest, which is a weaker claim and reads as one. It sits
        // below, in secondary type, with no call to action: someone who wants it can
        // take it from the button row.
        if let latest = status.latestUpdateSummary {
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
    } trailing: {
      architectureTag
    }
    .confirmationDialog(
      pendingUpdate == .latest
        ? "Install the newest \(descriptor.displayName)?"
        : "Update \(descriptor.displayName)?",
      isPresented: .isPresent($pendingUpdate),
      titleVisibility: .visible
    ) {
      Button(pendingUpdate == .latest ? "Install Newest" : "Update") {
        let channel = pendingUpdate ?? .recommended
        Task { await model.installTool(descriptor.id, channel: channel) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(installConfirmationMessage)
    }
    .confirmationDialog(
      "Use this \(descriptor.displayName) anyway?",
      isPresented: .isPresent($unidentifiedChoice),
      titleVisibility: .visible
    ) {
      Button("Use It") {
        guard let path = unidentifiedChoice else { return }
        Task { await model.adoptToolBinary(path, for: descriptor.id) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(unidentifiedChoiceMessage)
    }
  }

  /// Stated plainly, because this is the one update in the app that can cut off the person
  /// taking it, and because the answer to "is that safe" is genuinely yes: the previous
  /// version stays on disk and going back needs no network.
  ///
  /// Built here rather than inline: three branches of string concatenation inside a
  /// `ViewBuilder` is what the type-checker gives up on.
  private var installConfirmationMessage: String {
    let kept =
      "The version you have now is kept, and Revert puts it back without downloading "
      + "anything."
    guard pendingUpdate == .latest else {
      return "The tunnel restarts, so connected clients reconnect. " + kept
    }
    if status.isLatestOutsideCompatibleRange {
      // Not "untested": somebody did test it, and this connection method cannot drive it.
      return "This build is outside the versions this server can drive"
        + requirementAside + ", so the connection is expected to fail. " + kept
    }
    return "This build is newer than the one BlueBubbles recommends, and has not been "
      + "tested with this server. The tunnel restarts, so connected clients reconnect. "
      + kept
  }

  private var unidentifiedChoiceMessage: String {
    "That program runs, but does not report a version BlueBubbles can read, so there is no "
      + "way to check it is one this server can drive" + requirementAside
      + ". You picked this file, so it will be used if you say so."
  }

  /// " (it needs 1.1.11 or newer, below 2.0.0)", or nothing for a tool with no range.
  private var requirementAside: String {
    descriptor.compatible.map { " (it needs \($0.summary))" } ?? ""
  }

  // MARK: - Pieces

  private var isFailed: Bool {
    if case .failed = status.activity { return true }
    return false
  }

  private var isBusy: Bool { status.isBusy }

  /// Says which build would be installed here, before anyone presses anything.
  ///
  /// An Intel Mac and an Apple Silicon Mac need different downloads, and a machine with no
  /// build available at all should say so rather than failing at the end of a download.
  private var architectureTag: some View {
    let host = ToolArchitecture.host
    let supported =
      descriptor.build(for: host) != nil
      || (host == .arm64 && descriptor.build(for: .x86_64) != nil)
    return Tag(
      supported ? host.displayName : "Not available for \(host.displayName)",
      tint: supported ? nil : StatusTone.attention.tint
    )
  }

  private var summaryRow: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: iconName)
        .foregroundStyle(iconColor)
        .font(.title3)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(status.installedSummary)
            .font(.body)
          if status.isOnRecommendedVersion { Tag("recommended") }
          if status.origin == .discovered { Tag("already on this Mac") }
        }
        if let recommendation = status.recommendationSummary {
          Text(recommendation)
            .font(.callout)
            .foregroundStyle(
              status.isOnRecommendedVersion ? StatusTone.good.tint : .secondary
            )
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
    switch status.origin {
    case .missing: "exclamationmark.circle"
    case .managed, .bundled, .external, .discovered: "checkmark.circle.fill"
    }
  }

  private var iconColor: Color {
    (status.origin == .missing ? StatusTone.attention : .good).tint
  }

  private var buttons: some View {
    let offered = status.buttons
    return HStack(spacing: 10) {
      switch offered.install {
      case .install(let version):
        // The label says which version, because "Install" alone leaves someone with a
        // number appearing afterwards that they never agreed to.
        Button(version.map { "Install \($0)" } ?? "Install") {
          Task { await model.installTool(descriptor.id) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
      case .update, .reinstall:
        // Deliberately a confirmation rather than a one-tap update: see the dialog.
        Button(offered.install == .update ? "Update" : "Reinstall") {
          pendingUpdate = .recommended
        }
        .disabled(isBusy)
      case .none:
        EmptyView()
      }

      // Only reachable while copies on this Mac are being ignored on purpose: with the
      // preference on Automatic a usable copy is already in use. So this is the way back,
      // and it sits beside the download it is the alternative to.
      if let version = offered.useCopyOnThisMac {
        Button("Use \(descriptor.displayName) \(version) on This Mac") {
          Task { await model.useAnyAvailableCopy(descriptor.id) }
        }
        .disabled(isBusy)
      }

      if offered.checkForUpdates {
        Button("Check for Updates") {
          Task { await model.checkToolForUpdate(descriptor.id) }
        }
        .disabled(isBusy)
      }

      if offered.revert {
        // No network, no download: the whole reason the previous version is kept.
        Button("Revert") { Task { await model.revertTool(descriptor.id) } }
          .disabled(isBusy)
      }

      Spacer()

      // The escape hatch for someone waiting on a fix the recommended version does not
      // have. Small, late in the row, and never the prominent choice, but present,
      // because the alternative is that they go and install it by hand outside this
      // mechanism entirely.
      if offered.installNewest {
        Button("Install Newest…") { pendingUpdate = .latest }
          .controlSize(.small)
          .disabled(isBusy)
      }

      // The label says "dedicated" rather than "install", because it also stops a copy
      // somebody else installed being used.
      if offered.installDedicatedCopy {
        Button("Install a Dedicated Copy") {
          Task { await model.useDedicatedToolInstall(descriptor.id) }
        }
        .controlSize(.small)
        .disabled(isBusy)
      }

      if offered.checkAgain {
        Button("Check Again") { Task { await model.rescanForToolCopy(descriptor.id) } }
          .controlSize(.small)
          .disabled(isBusy)
          .help("Look again for a copy already installed on this Mac.")
      }

      if offered.stopUsingChosenCopy {
        Button("Stop Using It") { Task { await model.clearToolBinary(descriptor.id) } }
          .controlSize(.small)
          .disabled(isBusy)
      } else {
        Button("Choose Existing…") {
          Task { unidentifiedChoice = await model.chooseToolBinary(descriptor.id) }
        }
        .controlSize(.small)
        .disabled(isBusy)
        .help("Use a copy already on this Mac, for an offline install.")
      }
    }
  }

  private var isCopyRefused: Bool {
    switch status.copyOnThisMac {
    case .incompatible, .unreadableVersion: true
    default: false
    }
  }

  /// Where it comes from and what checked it: stated, because a user is being asked to let
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
      if let checked = status.state.lastCheckedAt {
        Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption).foregroundStyle(.tertiary)
      }
    }
  }

  private var verificationSummary: String {
    // A copy this server did not fetch was not checked by any of the rules below, and
    // saying otherwise would be describing a download that never happened.
    if status.origin == .discovered || status.origin == .external {
      return "This copy was installed on this Mac by something else. BlueBubbles did not "
        + "download or verify it; it checked that it runs and which version it reports."
    }
    return switch descriptor.signature {
    case .pinnedTeam(let team):
      "Downloads are accepted only when signed by \(team)."
    case .trustOnFirstUse:
      status.state.pinnedTeamID.map {
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
