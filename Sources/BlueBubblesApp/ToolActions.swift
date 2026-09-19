//  ToolActions
//  The Install / Update / Revert buttons, joined to `ToolManager`.
//
//  A separate file from `AppModel` because it is a self-contained slice (the statuses, the
//  five actions on them, and the stream that keeps a download's progress bar moving) and
//  `AppModel` is already the file everything ends up in.
//
//  Nothing here decides anything. Every action is something a person pressed, which is the
//  invariant the whole managed-tool design rests on: the server checks and reports, and a
//  human installs. See `ToolManager` for why an automatic update to the tunnel binary is the
//  one update that must never happen unattended.

import AppKit
import BBCore
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

  /// Follows tool status for the life of the server.
  ///
  /// Subscribed before the seed read, so no change falls between them. Following the
  /// stream rather than reading once is what makes a download's progress bar move: an
  /// install runs for tens of seconds, and a view that read the status once would show
  /// "downloading 0%" for all of it. Cancelled by `stopFollowingServer`.
  func followTools(_ tools: ToolManager) {
    toolsTask?.cancel()
    toolsTask = Task { [weak self] in
      let changes = await tools.stream()
      self?.apply(await tools.statuses())
      for await status in changes {
        self?.apply([status])
      }
    }
  }

  private func apply(_ statuses: [ToolStatus]) {
    for status in statuses { toolStatuses[status.id] = status }
  }

  // MARK: - Actions

  /// Installs the version the plugin recommends, or the newest published one.
  ///
  /// Recommended by default at every call site that does not say otherwise: the common case
  /// should be the version someone has tested, and taking the newest build should be a
  /// decision rather than what happens when a button is pressed.
  func installTool(_ toolID: String, channel: ToolChannel = .recommended) async {
    guard let tools else { return }
    // Failures are surfaced as an alert by the manager itself and as `.failed` on the
    // status here, so nothing is swallowed by this `try?`; it is not the reporting path.
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
  /// on a machine whose connection is the problem being solved, and a copy the scan did not
  /// reach is still a copy. A file chooser rather than a text field so the path is real by
  /// construction.
  ///
  /// Returns a path whose version could not be read, for the caller to confirm. The decision
  /// belongs to the view, not here: this method owns an `NSOpenPanel`, which is plumbing,
  /// and "use a program we could not identify" is a choice a person makes.
  func chooseToolBinary(_ toolID: String) async -> String? {
    guard let tools, let descriptor = toolStatuses[toolID]?.descriptor else { return nil }

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

    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    do {
      _ = try await tools.adoptExternalBinary(at: url.path, for: toolID)
    } catch let error as ToolError {
      if case .externalBinaryVersionUnreadable(_, let path) = error {
        await refreshTool(toolID)
        return path
      }
      await reportToolChoice(error)
    } catch {
      await reportToolChoice(error)
    }
    await refreshTool(toolID)
    return nil
  }

  /// Takes a program whose version could not be read, after the person said to.
  func adoptToolBinary(_ path: String, for toolID: String) async {
    guard let tools else { return }
    do {
      _ = try await tools.adoptExternalBinary(
        at: path, for: toolID, allowUnknownVersion: true
      )
    } catch {
      await reportToolChoice(error)
    }
    await refreshTool(toolID)
  }

  private func reportToolChoice(_ error: any Error) async {
    await alertCenter?.raise(
      UserAlert(
        severity: .warning,
        title: "That program cannot be used",
        body: DiagnosticText.sentence(for: error),
        source: "Programs"
      )
    )
  }

  /// Goes back to the managed install after a chosen binary.
  func clearToolBinary(_ toolID: String) async {
    guard let tools else { return }
    try? await tools.clearExternalBinary(for: toolID)
    await refreshTool(toolID)
  }

  /// Stops using anything this server did not install, and installs one.
  ///
  /// The two halves are one action because choosing the dedicated install while nothing is
  /// installed would otherwise leave the connection with no program at all.
  func useDedicatedToolInstall(_ toolID: String) async {
    guard let tools else { return }
    try? await tools.setPreference(.dedicated, for: toolID)
    await refreshTool(toolID)
    if await tools.status(of: toolID)?.executablePath == nil {
      await installTool(toolID)
    }
  }

  /// Goes back to using whatever is already on this Mac.
  func useAnyAvailableCopy(_ toolID: String) async {
    guard let tools else { return }
    try? await tools.setPreference(.automatic, for: toolID)
    await tools.scanForExistingCopy(toolID)
    await refreshTool(toolID)
  }

  /// Looks again, for someone who has just installed one.
  func rescanForToolCopy(_ toolID: String) async {
    guard let tools else { return }
    await tools.scanForExistingCopy(toolID)
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
      state.externalProbe?.version.map {
        "Using \(descriptor.displayName) \($0), which you chose: \(state.externalPath ?? "")"
      } ?? "Using a program you chose: \(state.externalPath ?? "")"
    case .discovered:
      state.discovered?.version.map {
        "Using \(descriptor.displayName) \($0), already installed on this Mac "
          + "(\(state.discovered?.executablePath ?? ""))."
      } ?? "Using a copy already installed on this Mac."
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

  /// What is on this Mac that this server did not install, when that is worth saying.
  ///
  /// Silent for the case that needs no words: a usable copy that IS the one in use, which
  /// `installedSummary` has already named. The rest are the states the page could not
  /// describe at all before — a copy sitting there refused, or one available while a
  /// downloaded copy is in use.
  var copyOnThisMacSummary: String? {
    switch copyOnThisMac {
    case .notConsidered, .notLookedYet, .none:
      nil
    case .usable(let path, let version):
      origin == .discovered
        ? nil
        : "\(descriptor.displayName) \(version) is also installed on this Mac, at \(path)."
    case .incompatible(let path, let version, let requirement):
      "\(descriptor.displayName) \(version) is installed on this Mac at \(path), but this "
        + "server needs \(requirement), so it is not being used."
    case .unreadableVersion(let path):
      "There is a copy at \(path), but it does not report a version this server can read, "
        + "so it is not being used on its own."
    }
  }

  /// Whether the scan has not answered yet, so the page can wait rather than offer a
  /// download one second before a copy would have been found.
  var isLookingForCopyOnThisMac: Bool { copyOnThisMac == .notLookedYet }

  /// A newer RECOMMENDED version: the offer worth acting on.
  var recommendedUpdateSummary: String? {
    guard let update = state.recommendedUpdate else { return nil }
    return "Version \(update.version) is now recommended."
  }

  /// Something newer than recommended. Available, deliberately not advised.
  var latestUpdateSummary: String? {
    guard let update = state.latestUpdate else { return nil }
    if isLatestOutsideCompatibleRange {
      // zrok is the live case: 2.x is published, and it removed the subcommand this
      // connection method opens a reserved share with. "Not tested" would be the wrong
      // claim — somebody did test it, and it does not work.
      return "\(descriptor.displayName) \(update.version) is the newest published build, "
        + "and this server cannot drive it: it needs \(descriptor.compatible?.summary ?? "")."
    }
    return update.version == ResolvedRelease.unknownVersion
      ? "A newer build has been published."
      : "\(descriptor.displayName) \(update.version) is the newest published build."
  }

  /// Whether the newest published build is one this server is known NOT to be able to drive.
  ///
  /// The offer stays — reversing a decision recorded in `BuiltInTools` silently would be
  /// worse, and someone may have a reason — but "nothing here has been tested against it"
  /// stops being true and the wording has to move with it.
  var isLatestOutsideCompatibleRange: Bool {
    guard let update = state.latestUpdate, update.version != ResolvedRelease.unknownVersion,
      let range = descriptor.compatible
    else { return false }
    return !range.contains(update.version)
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
