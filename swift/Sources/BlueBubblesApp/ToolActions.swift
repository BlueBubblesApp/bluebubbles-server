//  ToolActions
//  The Install / Update / Revert buttons, joined to `ToolManager`.
//
//  A separate file from `AppModel` because it is a self-contained slice — the statuses, the
//  five actions on them, and the stream that keeps a download's progress bar moving — and
//  `AppModel` is already the file everything ends up in.
//
//  Nothing here decides anything. Every action is something a person pressed, which is the
//  invariant the whole managed-tool design rests on: the server checks and reports, and a
//  human installs. See `ToolManager` for why an automatic update to the tunnel binary is the
//  one update that must never happen unattended.

import AppKit
import BBDiagnostics
import BBInterfaces
import BBServiceKit
import BBTooling
import BlueBubblesServerCore
import Foundation

@MainActor
extension AppModel {

  /// The status of every managed program, keyed by tool id.
  var toolStatusList: [ToolStatus] { toolStatuses.values.sorted { $0.id < $1.id } }

  func toolStatus(_ toolID: String) -> ToolStatus? { toolStatuses[toolID] }

  /// Loads current statuses and follows changes.
  ///
  /// Called when a page showing a tool appears. Following the stream rather than polling is
  /// what makes a download's progress bar move — an install runs for tens of seconds and a
  /// view that read the status once would show "downloading 0%" for all of it.
  func beginObservingTools() {
    guard let tools else { return }
    // REFERENCE COUNTED, because `begin` being idempotent was only half the problem it
    // described. Two views observing at once — the Integrations page and the Connection
    // Method row — shared one subscription, and the first of them to disappear cancelled it
    // for the other, which then showed a download stuck at whatever percentage it had
    // reached. Counting means the stream lives exactly as long as somebody is watching.
    toolObservers += 1
    guard toolsTask == nil else { return }
    toolsTask = Task { [weak self] in
      let statuses = await tools.statuses()
      self?.apply(statuses)
      for await status in await tools.stream() {
        if Task.isCancelled { return }
        self?.apply([status])
      }
    }
  }

  func endObservingTools() {
    toolObservers = max(0, toolObservers - 1)
    guard toolObservers == 0 else { return }
    toolsTask?.cancel()
    toolsTask = nil
  }

  private func apply(_ statuses: [ToolStatus]) {
    for status in statuses { toolStatuses[status.id] = status }
  }

  // MARK: - Actions

  /// Installs the version the plugin recommends, or the newest published one.
  ///
  /// Recommended by default at every call site that does not say otherwise — the common case
  /// should be the version someone has tested, and taking the newest build should be a
  /// decision rather than what happens when a button is pressed.
  func installTool(_ toolID: String, channel: ToolChannel = .recommended) async {
    guard let tools else { return }
    // Failures are surfaced as an alert by the manager itself and as `.failed` on the
    // status here, so nothing is swallowed by this `try?` — it is not the reporting path.
    _ = try? await tools.install(toolID, channel: channel)
    await refreshTool(toolID)
  }

  func checkToolForUpdate(_ toolID: String) async {
    guard let tools else { return }
    _ = try? await tools.checkForUpdate(toolID)
    await refreshTool(toolID)
  }

  func revertTool(_ toolID: String) async {
    guard let tools else { return }
    try? await tools.revert(toolID)
    await refreshTool(toolID)
  }

  /// Lets someone point at a copy they already have.
  ///
  /// The offline path, and the reason it exists: setting up a tunnel is something people do
  /// on a machine whose connection is the problem being solved, and Homebrew users often
  /// already have the binary. A file chooser rather than a text field so the path is real by
  /// construction.
  func chooseToolBinary(_ toolID: String) async {
    guard let tools, let descriptor = toolStatuses[toolID]?.descriptor else { return }

    let panel = NSOpenPanel()
    panel.title = "Choose \(descriptor.displayName)"
    panel.message = "Pick the \(descriptor.executableName) program to use."
    panel.prompt = "Use This"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    // Started somewhere a hand-installed binary plausibly is, rather than in Documents.
    panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
    panel.showsHiddenFiles = true

    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try await tools.adoptExternalBinary(at: url.path, for: toolID)
    } catch {
      await alertCenter?.raise(
        UserAlert(
          severity: .warning,
          title: "That program cannot be used",
          body: String(describing: error),
          source: "Programs"
        )
      )
    }
    await refreshTool(toolID)
  }

  /// Goes back to the managed install after a chosen binary.
  func clearToolBinary(_ toolID: String) async {
    guard let tools else { return }
    try? await tools.clearExternalBinary(for: toolID)
    await refreshTool(toolID)
  }

  private func refreshTool(_ toolID: String) async {
    guard let tools, let status = await tools.status(of: toolID) else { return }
    toolStatuses[toolID] = status
  }
}

// MARK: - Presentation

extension ToolStatus {

  /// One line describing what is installed, written for a person.
  var installedSummary: String {
    switch origin {
    case .external:
      "Using a program you chose: \(state.externalPath ?? "")"
    case .bundled:
      "Using the copy that shipped with this app."
    case .managed:
      if let installed = state.installed {
        installed.version == ResolvedRelease.unknownVersion
          // A rolling source has no version to show, so the install date is the only
          // honest way to say which build this is.
          ? "Installed \(Self.dateText(installed.installedAt)) "
            + "(\(installed.architecture.displayName))"
          : "Version \(installed.version) (\(installed.architecture.displayName))"
      } else {
        "Installed."
      }
    case .missing:
      recommendedVersion.map { "Not installed. Version \($0) is recommended." }
        ?? "Not installed."
    }
  }

  /// The reassurance line, and the one the page leads with.
  ///
  /// Being on the tested version is the good state, so it is stated as one. Without this the
  /// page has nothing to say about a healthy install except a version number, and a "3.1.0 is
  /// available" note underneath it reads as something being wrong.
  var recommendationSummary: String? {
    guard descriptor.recommended != nil, origin == .managed else { return nil }
    if isOnRecommendedVersion {
      return "This is the version BlueBubbles recommends."
    }
    guard let recommended = recommendedVersion else { return nil }
    return state.installed?.channel == .latest
      ? "You chose the newest published build. Version \(recommended) is the one "
        + "BlueBubbles recommends."
      : "Version \(recommended) is recommended."
  }

  /// A newer RECOMMENDED version — the offer worth acting on.
  var recommendedUpdateSummary: String? {
    guard let update = state.recommendedUpdate else { return nil }
    return "Version \(update.version) is now recommended."
  }

  /// Something newer than recommended. Available, deliberately not advised.
  var latestUpdateSummary: String? {
    guard let update = state.latestUpdate else { return nil }
    return update.version == ResolvedRelease.unknownVersion
      ? "A newer build has been published."
      : "\(descriptor.displayName) \(update.version) is the newest published build."
  }

  var activitySummary: String? {
    switch activity {
    case .idle: nil
    case .checking: "Checking…"
    case .failed(let reason): reason
    case .installing(let phase):
      switch phase {
      case .resolving: "Looking up the current version…"
      case .downloading(let fraction): "Downloading… \(Int(fraction * 100))%"
      case .verifying: "Checking the signature…"
      case .unpacking: "Unpacking…"
      case .activating: "Finishing…"
      }
    }
  }

  /// 0…1 while downloading; nil otherwise, so the bar is shown only when it means something.
  var downloadFraction: Double? {
    if case .installing(.downloading(let fraction)) = activity { return fraction }
    return nil
  }

  private static func dateText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }
}
