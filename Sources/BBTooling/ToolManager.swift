//  ToolManager
//  The one place that knows which external programs exist, where they are, and whether
//  something newer has been published.
//
//  Everything a service does with a tool goes through here, and the reason it is a single
//  actor rather than a helper each service constructs is sharing: two services that both need
//  cloudflared share one 38 MB install, one update check and one decision about whether to
//  take an update. A per-service downloader would give them two copies that disagree.
//
//  **It never updates anything on its own, and that is a deliberate refusal rather than an
//  unimplemented feature.** The tool being updated is, for most installs, the tunnel: the
//  only route to this Mac. An update that breaks it breaks the connection the user would need
//  in order to notice, and they are by definition not at the machine, because being away from
//  the machine is what the tunnel is for. So: check, report, offer. The install is a person's
//  decision, the previous version stays on disk, and going back is one click and no network.
//
//  See `.claude/docs/performance.md` and TODO.md "Tunnel binaries".

import BBCore
import BBDiagnostics
import BBServiceKit
import Foundation
import Logging

// MARK: - What the UI reads

/// Where the executable being used came from.
public enum ToolOrigin: String, Sendable, Equatable, Codable {
  /// Downloaded and managed here.
  case managed
  /// A binary the user pointed at: an offline install, or a copy they chose by hand.
  case external
  /// A copy that was already on this Mac when we looked, and that nobody chose.
  ///
  /// Kept apart from `external` because the difference decides behaviour, not just wording:
  /// an explicit choice is honoured even when the copy later drifts out of range (loudly),
  /// and this one is not, because the version test is the whole of its licence to be used.
  case discovered
  /// Shipped inside the app bundle. The fallback, so a build that does bundle its binaries
  /// keeps working unchanged.
  case bundled
  case missing
}

public enum ToolActivity: Sendable, Equatable {
  case idle
  case checking
  case installing(ToolInstallPhase)
  /// The last attempt failed, and this is what it said. Cleared by the next attempt.
  case failed(String)
}

/// What a scan found on this Mac, ready for a page to render.
///
/// Derived in `status(of:)` rather than stored, so that a range which moves when the server
/// updates re-judges an old recording instead of contradicting it. Lives here rather than on
/// a view because it is a decision, and a decision on a `View` cannot be tested.
public enum ToolCopyOnThisMac: Sendable, Equatable {
  /// This tool declares no compatible range, so a copy on this Mac is never adopted.
  case notConsidered
  case notLookedYet
  case none
  case usable(path: String, version: String)
  case incompatible(path: String, version: String, requirement: String)
  case unreadableVersion(path: String)
}

public struct ToolStatus: Sendable, Equatable, Identifiable {
  public let descriptor: ManagedToolDescriptor
  public let state: ToolState
  public let activity: ToolActivity
  public let origin: ToolOrigin
  /// What a service would actually be handed right now.
  public let executablePath: String?
  /// A copy already on this Mac, judged against the range as of now.
  public let copyOnThisMac: ToolCopyOnThisMac
  /// Whether this tool may use a copy it did not install.
  public let preference: ToolPreference

  public var id: String { descriptor.id }
  public var installedVersion: String? { state.installed?.version }
  public var canRevert: Bool { state.previous != nil }
  /// The version this plugin says it works with, if it named one.
  public var recommendedVersion: String? { descriptor.recommended?.version }
  /// Whether what is installed is the version the plugin recommends.
  ///
  /// The state the UI leads with. "You are on the tested version" is the reassurance someone
  /// looking at this page wants, and a newer build existing does not change it.
  public var isOnRecommendedVersion: Bool {
    guard let recommended = descriptor.recommended else { return false }
    guard let installed = state.installed else { return false }
    return installed.version == recommended.version
  }
  /// A newer recommended version: the offer worth acting on.
  public var recommendedUpdate: AvailableUpdate? { state.recommendedUpdate }
  /// A newer build than the recommended one. Available, not advised.
  public var latestUpdate: AvailableUpdate? { state.latestUpdate }
  /// Whether an update is known to exist. Not whether one will be installed.
  public var hasUpdate: Bool { state.recommendedUpdate != nil || state.latestUpdate != nil }
  public var isBusy: Bool {
    switch activity {
    case .checking, .installing: true
    case .idle, .failed: false
    }
  }
}

// MARK: - The manager

public actor ToolManager {

  private let store: ToolStore
  private let resolver: ReleaseResolver
  private let installer: ToolInstaller
  private let alerts: (any AlertRaising)?
  private let logger: Logger
  /// The bundled fallback. A closure so this module needs to know nothing about app bundles,
  /// and so a test can supply one without one existing.
  private let bundledLocator: @Sendable (String) -> String?
  /// Finds copies already on this Mac. A value type, so the probes it runs happen off this
  /// actor rather than holding it for the length of a subprocess.
  private let discovery: ToolDiscovery

  private var descriptors: [String: ManagedToolDescriptor] = [:]
  private var states: [String: ToolState] = [:]
  private var activities: [String: ToolActivity] = [:]
  private var observers: [UUID: AsyncStream<ToolStatus>.Continuation] = [:]

  public init(
    store: ToolStore = ToolStore(),
    transport: any ToolTransport = URLSessionToolTransport(),
    alerts: (any AlertRaising)? = nil,
    bundledLocator: @escaping @Sendable (String) -> String? = { _ in nil },
    discovery: ToolDiscovery = ToolDiscovery(),
    logger: Logger = Logger(label: "bluebubbles.tools")
  ) {
    self.discovery = discovery
    self.store = store
    self.resolver = ReleaseResolver(transport: transport)
    self.installer = ToolInstaller(transport: transport, store: store, logger: logger)
    self.alerts = alerts
    self.bundledLocator = bundledLocator
    self.logger = logger
  }

  // MARK: Registration

  /// Declares the tools a manifest asks for.
  ///
  /// Idempotent, and last-writer-wins on a shared id: two services declaring cloudflared is
  /// the case this is built for, and they had better be describing the same program. The
  /// alternative (refusing the second) would mean a plugin could deny a built-in service
  /// its tool by declaring the same id first.
  public func register(_ manifests: [ServiceManifest]) {
    for manifest in manifests {
      for tool in manifest.tools where tool.isWellFormed {
        descriptors[tool.id] = tool
        if states[tool.id] == nil { states[tool.id] = store.load(tool.id) }
      }
    }
  }

  public func register(_ descriptor: ManagedToolDescriptor) {
    guard descriptor.isWellFormed else { return }
    descriptors[descriptor.id] = descriptor
    if states[descriptor.id] == nil { states[descriptor.id] = store.load(descriptor.id) }
  }

  // MARK: Reading

  public func statuses() -> [ToolStatus] {
    descriptors.keys.sorted().compactMap { status(of: $0) }
  }

  public func status(of toolID: String) -> ToolStatus? {
    guard let descriptor = descriptors[toolID] else { return nil }
    let state = states[toolID] ?? store.load(toolID)
    let resolution = resolve(descriptor: descriptor, state: state)
    return ToolStatus(
      descriptor: descriptor,
      state: state,
      activity: activities[toolID] ?? .idle,
      origin: resolution.origin,
      executablePath: resolution.path,
      copyOnThisMac: Self.copyOnThisMac(descriptor: descriptor, state: state),
      preference: state.effectivePreference
    )
  }

  /// The executable a service should run, or nil.
  ///
  /// Nil is a real answer with a real remedy attached; see the alert the proxy services
  /// raise, rather than something to paper over with a guess at a path.
  public func executablePath(for toolID: String) -> String? {
    guard let descriptor = descriptors[toolID] else { return nil }
    return resolve(descriptor: descriptor, state: states[toolID] ?? store.load(toolID)).path
  }

  /// A companion executable, beside whichever executable a service would be handed.
  ///
  /// Resolved from the same install as `executablePath(for:)`: managed, the user's own,
  /// or bundled, so the daemon and the tool that drives it can never come from two
  /// different versions. Nil when the tool is not installed, when the descriptor declares
  /// no such companion, or when the install lacks it.
  public func companionExecutablePath(for toolID: String, named name: String) -> String? {
    guard let descriptor = descriptors[toolID],
      descriptor.companionExecutables.contains(name),
      let executable = executablePath(for: toolID)
    else { return nil }
    let candidate = (executable as NSString).deletingLastPathComponent + "/" + name
    return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
  }

  /// Preference order: what the user chose, then what we manage, then what was already here,
  /// then what shipped.
  ///
  /// The user's own choice wins because pointing at a binary is an explicit act: someone who
  /// has done it is working around something, and silently preferring our download would undo
  /// the workaround without saying so. For the same reason it is honoured even when the copy
  /// has since drifted out of range — the scan says so loudly instead of overriding them.
  ///
  /// **A copy found on this Mac sits BELOW the managed install, and that is the whole of the
  /// design.** Discovery exists so a duplicate is never DOWNLOADED, which is served completely
  /// by filling the empty slot; it was never a reason to change what a working server runs. A
  /// managed install only ever exists because a person pressed Install — nothing here
  /// downloads itself — so demoting it to an unowned Homebrew copy would undo a deliberate act
  /// on a schedule nobody set. It is also the less predictable of the two: `brew upgrade` can
  /// replace it without anyone touching BlueBubbles, while the managed copy moves only when
  /// somebody presses a button on this page. And Update, Revert and the two-version prune all
  /// operate on the managed install, so preferring discovery would leave Revert a button that
  /// appears to work and changes nothing.
  private func resolve(
    descriptor: ManagedToolDescriptor, state: ToolState
  ) -> (path: String?, origin: ToolOrigin) {
    let preference = state.effectivePreference

    if preference == .automatic, let external = state.externalPath,
      FileManager.default.isExecutableFile(atPath: external)
    {
      return (external, .external)
    }
    if let installed = state.installed,
      FileManager.default.isExecutableFile(atPath: installed.executablePath)
    {
      return (installed.executablePath, .managed)
    }
    // Every condition here is a licence to run someone else's program that nobody chose:
    // the record still describes the file, it answered with a version, and the version is
    // one the declaring service says it can drive.
    if preference == .automatic, let found = state.discovered, found.isCurrent,
      let version = found.version, descriptor.compatible?.contains(version) == true,
      FileManager.default.isExecutableFile(atPath: found.executablePath)
    {
      return (found.executablePath, .discovered)
    }
    if let bundled = bundledLocator(descriptor.executableName) {
      return (bundled, .bundled)
    }
    return (nil, .missing)
  }

  /// Judges a recorded copy against the range as it stands NOW.
  ///
  /// Not stored alongside the recording: the range travels inside the application and moves
  /// when the server updates, so a persisted verdict would be a stale answer to a question
  /// whose rule had changed under it.
  static func copyOnThisMac(
    descriptor: ManagedToolDescriptor, state: ToolState
  ) -> ToolCopyOnThisMac {
    guard let range = descriptor.compatible else { return .notConsidered }
    guard state.lastScanAt != nil else { return .notLookedYet }
    guard let found = state.discovered, found.isCurrent else { return .none }
    switch found.outcome {
    case .ran(let version):
      return range.contains(version)
        ? .usable(path: found.executablePath, version: version)
        : .incompatible(
          path: found.executablePath, version: version, requirement: range.summary)
    case .versionUnreadable:
      return .unreadableVersion(path: found.executablePath)
    case .wouldNotRun:
      // Almost always the wrong architecture. Nothing a person can do about that copy, so
      // it reads as "there is nothing here" rather than as a problem to solve.
      return .none
    }
  }

  // MARK: Installing

  /// Installs, or reinstalls, the current build.
  ///
  /// The same call is "install" and "update" on purpose: they are the same operation, and
  /// having two would invite them to diverge in exactly the step that keeps the old version
  /// around.
  ///
  /// Defaults to the RECOMMENDED channel: the version the declaring plugin was tested
  /// against. A user who wants the newest published build asks for it explicitly, which is
  /// the right way round: the common case should be the one someone has verified, and the
  /// uncommon case should be a decision.
  @discardableResult
  public func install(
    _ toolID: String, channel: ToolChannel = .recommended
  ) async throws -> InstalledBuild {
    guard let descriptor = descriptors[toolID] else { throw ToolError.unknownTool(toolID) }
    guard !(status(of: toolID)?.isBusy ?? false) else { throw ToolError.busy(tool: toolID) }

    var state = states[toolID] ?? store.load(toolID)
    // Opened BEFORE the first activity is published and closed before the last one, so a
    // progress update that arrives late has something to test itself against. See
    // `noteInstallProgress`.
    installsInFlight.insert(toolID)
    set(activity: .installing(.resolving), for: toolID)

    do {
      let release = try await resolver.resolve(descriptor, channel: channel)
      let installed = try await installer.install(
        descriptor,
        release: release,
        pinnedTeamID: state.pinnedTeamID
      ) { [weak self] phase in
        // Hops onto the actor to publish; the installer itself is not isolated, which
        // is what lets a download run without holding the actor for thirty seconds.
        //
        // Through `noteInstallProgress` rather than `set`, because the hop is an
        // UNSTRUCTURED task and nothing orders it against the end of the install. A phase
        // reported just before `installer.install` returns can be scheduled AFTER this
        // method has set `.idle`, which puts the tool back into `.installing` with no
        // install behind it: a row in the background list, with a spinner, that nothing
        // clears until the next install or update check.
        Task { [weak self] in await self?.noteInstallProgress(phase, for: toolID) }
      }

      // The version being replaced becomes the one revert goes back to: unless it IS
      // this version, in which case a reinstall would otherwise leave `previous`
      // pointing at a directory that was just overwritten.
      if let current = state.installed, current.executablePath != installed.executablePath {
        state.previous = current
      }
      state.installed = installed
      // Both offers are cleared and recomputed by the next check rather than reasoned
      // about here: what is now installed may satisfy one, the other, both or neither,
      // and guessing at that is how a page ends up offering someone the version they are
      // already running.
      state.recommendedUpdate = nil
      state.latestUpdate = nil
      state.note = release.recommendationUnavailable
      state.lastValidator = release.validator
      if state.pinnedTeamID == nil { state.pinnedTeamID = installed.teamID }
      if let note = release.recommendationUnavailable {
        logger.warning(
          "A recommended tool version could not be installed",
          metadata: [
            "tool": .string(toolID), "detail": .string(note),
          ])
      }
      try store.save(state)
      states[toolID] = state
      prune(toolID: toolID, state: state)

      installsInFlight.remove(toolID)
      set(activity: .idle, for: toolID)
      return installed
    } catch {
      installsInFlight.remove(toolID)
      let description = (error as? ToolError)?.description ?? String(describing: error)
      set(activity: .failed(description), for: toolID)
      logger.error(
        "Tool install failed",
        metadata: [
          "tool": .string(toolID), "error": .string(description),
        ])
      await alerts?.raise(
        UserAlert(
          severity: .error,
          title: "Could not install \(descriptor.displayName)",
          body: description,
          source: "Programs",
          diagnostics: Diagnostics(
            code: (error as? ToolError)?.code,
            domain: "tools",
            context: [
              "tool": .string(toolID),
              "architecture": .string(ToolArchitecture.host.rawValue),
            ]
          ),
          dedupeKey: "tool.install.\(toolID)"
        )
      )
      throw error
    }
  }

  /// Goes back to the version that was installed before the current one.
  ///
  /// A symlink repoint and nothing else. No network, which is the entire point: the reason
  /// to revert a tunnel is usually that the tunnel stopped working, and at that moment this
  /// Mac may not be reachable and may not even be online.
  public func revert(_ toolID: String) throws {
    guard let descriptor = descriptors[toolID] else { throw ToolError.unknownTool(toolID) }
    var state = states[toolID] ?? store.load(toolID)
    guard let previous = state.previous else {
      throw ToolError.nothingToRevertTo(tool: descriptor.id)
    }

    let layout = store.layout(for: toolID)
    try installer.activate(
      layout.versionDirectory(version: previous.version, architecture: previous.architecture),
      layout: layout,
      toolID: toolID
    )
    state.previous = state.installed
    state.installed = previous
    // The update that was just backed out is still available, and saying so is honest:
    // the user may have reverted to wait for a fix rather than to refuse it forever.
    try store.save(state)
    states[toolID] = state
    publish(toolID)
  }

  /// Uses a binary the user already has.
  ///
  /// The offline path. Someone setting up a tunnel may have no working connection: that is
  /// frequently why they are setting up a tunnel, and "download it" cannot be the only way
  /// to have one. It also covers a Homebrew install the scan did not reach.
  ///
  /// It now runs the same checks the scan does — companions beside it, not somewhere any
  /// user could write, and what version it reports — because the old version of this checked
  /// only that the file had the execute bit, which let someone adopt a build far too old to
  /// drive and find out when the tunnel failed to start, on a machine they were not sitting
  /// at.
  ///
  /// `allowUnknownVersion` is the one place this is looser than the scan, and deliberately.
  /// `ToolInstaller` already argues that a binary which ran and printed something unexpected
  /// has passed the check that matters, and that refusing over an unparseable string refuses
  /// a working binary. That holds for a file a person pointed at. It collapses for a copy
  /// found by scanning, where the version IS the whole basis for using it.
  @discardableResult
  public func adoptExternalBinary(
    at path: String, for toolID: String, allowUnknownVersion: Bool = false
  ) async throws -> ProbedCopy {
    guard let descriptor = descriptors[toolID] else { throw ToolError.unknownTool(toolID) }

    let probe = try await discovery.inspect(path, as: descriptor)
    switch probe.outcome {
    case .ran(let version):
      if let range = descriptor.compatible, !range.contains(version) {
        throw ToolError.externalBinaryIncompatible(
          tool: descriptor.id, path: path, version: version, requirement: range.summary
        )
      }
    case .versionUnreadable:
      // A tool declaring no range has no claim to check, so there is nothing to waive and
      // nothing to ask about: this is the offline escape hatch working as it always did.
      if descriptor.compatible != nil && !allowUnknownVersion {
        throw ToolError.externalBinaryVersionUnreadable(tool: descriptor.id, path: path)
      }
    case .wouldNotRun:
      // `inspect` has already thrown for this.
      break
    }

    var state = states[toolID] ?? store.load(toolID)
    state.externalPath = path
    state.externalProbe = probe
    // Choosing a copy is the opposite of asking for a dedicated one, so it says so rather
    // than leaving a preference set that would ignore what was just chosen.
    state.preference = .automatic
    try store.save(state)
    states[toolID] = state
    publish(toolID)
    return probe
  }

  public func clearExternalBinary(for toolID: String) throws {
    guard descriptors[toolID] != nil else { throw ToolError.unknownTool(toolID) }
    var state = states[toolID] ?? store.load(toolID)
    state.externalPath = nil
    state.externalProbe = nil
    try store.save(state)
    states[toolID] = state
    publish(toolID)
  }

  /// Which copy of a program to use.
  ///
  /// Setting `.dedicated` CLEARS any chosen path rather than shadowing it. If both could be
  /// set at once, a path the user had forgotten about would reappear the moment the
  /// preference flipped back, and the resolver would have to arbitrate between two
  /// instructions from the same person.
  public func setPreference(_ preference: ToolPreference, for toolID: String) throws {
    guard descriptors[toolID] != nil else { throw ToolError.unknownTool(toolID) }
    var state = states[toolID] ?? store.load(toolID)
    state.preference = preference
    if preference == .dedicated {
      state.externalPath = nil
      state.externalProbe = nil
    }
    try store.save(state)
    states[toolID] = state
    publish(toolID)
  }

  // MARK: - Looking for copies already on this Mac

  /// What one tool's scan produced, computed off the actor.
  private struct ScanOutcome: Sendable {
    let toolID: String
    let discovered: ProbedCopy?
    let externalProbe: ProbedCopy?
  }

  /// Looks for copies of every registered program that are already on this Mac.
  ///
  /// The SCAN, not the resolution. `executablePath(for:)` is synchronous because it is
  /// reached at service start, and probing a binary is not, so the answer is written into
  /// each tool's state here and read back there.
  ///
  /// **Steady state costs nothing.** A tool whose recorded copy still fingerprints the same
  /// is not probed again, so after the first run this is a handful of `stat` calls. The
  /// probe happens on a first run, a fresh install, or a `brew upgrade`, and nowhere else.
  public func scanForExistingCopies() async {
    let work = descriptors.values
      .filter(\.acceptsPreexistingCopies)
      .sorted { $0.id < $1.id }
      .map { descriptor -> (ManagedToolDescriptor, ToolState) in
        let state = states[descriptor.id] ?? store.load(descriptor.id)
        states[descriptor.id] = state
        return (descriptor, state)
      }
    guard !work.isEmpty else { return }

    let discovery = self.discovery
    let outcomes = await withTaskGroup(of: ScanOutcome.self) { group in
      for (descriptor, state) in work {
        group.addTask { await Self.scan(descriptor, state: state, discovery: discovery) }
      }
      var collected: [ScanOutcome] = []
      for await outcome in group { collected.append(outcome) }
      return collected
    }
    for outcome in outcomes { await apply(outcome) }
  }

  /// One tool, for the button that says Check Again.
  public func scanForExistingCopy(_ toolID: String) async {
    guard let descriptor = descriptors[toolID], descriptor.acceptsPreexistingCopies else {
      return
    }
    let state = states[toolID] ?? store.load(toolID)
    await apply(await Self.scan(descriptor, state: state, discovery: discovery))
  }

  /// Off the actor: the part that spawns processes.
  private static func scan(
    _ descriptor: ManagedToolDescriptor, state: ToolState, discovery: ToolDiscovery
  ) async -> ScanOutcome {
    var external = state.externalProbe
    if let path = state.externalPath, external?.isCurrent != true {
      // A refusal here is not thrown away: the copy stays in use and the drift alert below
      // is what says something changed. Silently dropping a path a person chose would be
      // overriding them.
      external = try? await discovery.inspect(path, as: descriptor)
    }
    var found = state.discovered
    if found?.isCurrent != true {
      found = await discovery.find(descriptor)
    }
    return ScanOutcome(toolID: descriptor.id, discovered: found, externalProbe: external)
  }

  private func apply(_ outcome: ScanOutcome) async {
    guard let descriptor = descriptors[outcome.toolID] else { return }
    var state = states[outcome.toolID] ?? store.load(outcome.toolID)
    // Asked of the RECORD rather than by re-resolving, because by the time a scan runs the
    // file has already been replaced: `resolve` would refuse the stale record as not
    // current and report that nothing was in use, which is exactly the change worth
    // announcing. See `wasUsingDiscoveredCopy`.
    let wasUsingDiscovered = wasUsingDiscoveredCopy(descriptor: descriptor, state: state)

    state.discovered = outcome.discovered
    state.externalProbe = outcome.externalProbe
    state.lastScanAt = Date()
    do {
      try store.save(state)
    } catch {
      // The scan still applies in memory: losing the record costs a re-probe next launch,
      // not the use of a copy that was found.
      logger.warning(
        "Could not record the result of a program scan",
        metadata: [
          "tool": .string(outcome.toolID), "error": .string(String(describing: error)),
        ])
    }
    states[outcome.toolID] = state
    let after = resolve(descriptor: descriptor, state: state)
    publish(outcome.toolID)

    await reportDrift(
      descriptor: descriptor, state: state,
      wasUsingDiscovered: wasUsingDiscovered, after: after
    )
  }

  /// Whether the copy found on this Mac was the one being handed to services, judged from
  /// the record as it stood BEFORE this scan overwrote it.
  ///
  /// Mirrors `resolve`'s ordering deliberately, minus its `isCurrent` test: that test is
  /// what a replaced binary fails, and failing it is the event this exists to notice.
  private func wasUsingDiscoveredCopy(
    descriptor: ManagedToolDescriptor, state: ToolState
  ) -> Bool {
    guard state.effectivePreference == .automatic, state.externalPath == nil else {
      return false
    }
    if let installed = state.installed,
      FileManager.default.isExecutableFile(atPath: installed.executablePath)
    {
      return false
    }
    guard let version = state.discovered?.version else { return false }
    return descriptor.compatible?.contains(version) == true
  }

  /// Says out loud when a copy this server was USING has changed under it.
  ///
  /// `brew upgrade` replaces a binary without anyone touching BlueBubbles, and zrok 2 is the
  /// worked example: the upgrade lands, the tunnel still starts, and opening a reserved share
  /// fails on a machine nobody is sitting at. A log line would be read afterwards; this is
  /// the remedy travelling with the problem.
  private func reportDrift(
    descriptor: ManagedToolDescriptor,
    state: ToolState,
    wasUsingDiscovered: Bool,
    after: (path: String?, origin: ToolOrigin)
  ) async {
    let requirement = descriptor.compatible?.summary ?? ""
    var body: String?

    if wasUsingDiscovered && after.origin != .discovered {
      let found = state.discovered
      body =
        "The \(descriptor.displayName) on this Mac that BlueBubbles was using has changed"
        + (found?.version.map { " and now reports version \($0)" } ?? "")
        + ". This server needs \(requirement), so it has stopped using that copy. Install "
        + "a dedicated copy to keep the connection working."
    } else if after.origin == .external, let probe = state.externalProbe,
      let version = probe.version, let range = descriptor.compatible,
      !range.contains(version)
    {
      body =
        "The \(descriptor.displayName) you chose, at \(probe.executablePath), is now "
        + "version \(version). This server needs \(requirement). It is still being used "
        + "because you chose it, and it may stop working."
    }

    guard let body else { return }
    let version = state.discovered?.version ?? state.externalProbe?.version ?? "unknown"
    logger.warning(
      "A program on this Mac changed out from under the connection method",
      metadata: [
        "tool": .string(descriptor.id), "version": .string(version),
      ])
    await alerts?.raise(
      UserAlert(
        severity: .warning,
        title: "\(descriptor.displayName) on this Mac has changed",
        body: body,
        source: "Programs",
        actions: [.installTool(id: descriptor.id)],
        // Keyed by the version it changed TO, so the next change is reported rather than
        // this one repeating forever.
        dedupeKey: "tool.copy-changed.\(descriptor.id).\(version)"
      )
    )
  }

  // MARK: Update checks

  /// Asks the vendor what is current. Never installs anything.
  @discardableResult
  public func checkForUpdate(_ toolID: String) async throws -> AvailableUpdate? {
    guard let descriptor = descriptors[toolID] else { throw ToolError.unknownTool(toolID) }
    var state = states[toolID] ?? store.load(toolID)
    // Nothing installed means nothing to update: "install" is the offer, and reporting
    // an available update for something absent would be a notification with no meaning.
    guard state.installed != nil else { return nil }

    set(activity: .checking, for: toolID)
    defer { set(activity: .idle, for: toolID) }

    let installedVersion = SemanticVersion(state.installed?.version ?? "0")
    state.lastCheckedAt = Date()

    // Two questions, deliberately kept apart.
    //
    // The first is whether the plugin now recommends something newer, which happens when
    // whatever ships the plugin is updated. That is a real recommendation from people who
    // tested it, and it is the only one that produces a notification.
    //
    // The second is whether the vendor has published something newer than that. It is a
    // weaker claim (nobody here has run it) so it is recorded and shown, and never
    // offered as the thing to do.
    var recommendedOffer: AvailableUpdate?
    if let recommended = descriptor.recommended,
      SemanticVersion(recommended.version) > installedVersion
    {
      recommendedOffer = AvailableUpdate(
        version: recommended.version, channel: .recommended
      )
    }

    let release = try await resolver.resolve(descriptor, channel: .latest)
    var latestOffer: AvailableUpdate?
    if release.isVersionKnownInAdvance {
      // Compared numerically. Lexically, `2024.9.1` sorts below `2024.10.0` and a
      // server would sit on an old tunnel indefinitely with nothing to show for it.
      let isNewer = SemanticVersion(release.version) > installedVersion
      // Not repeated as a second offer when the newest published build IS the
      // recommended one, which is the normal state of a well-maintained pin.
      let isBeyondRecommended =
        descriptor.recommended.map {
          SemanticVersion(release.version) > SemanticVersion($0.version)
        } ?? true
      if isNewer && isBeyondRecommended {
        latestOffer = AvailableUpdate(
          version: release.version,
          channel: .latest,
          releaseNotesURL: release.releaseNotesURL
        )
      }
    } else if let validator = release.validator, validator != state.lastValidator {
      // No version to compare, so the question is whether the bytes at the URL are the
      // ones we installed from. A vendor that sends no validator leaves this nil, and
      // "cannot tell" is reported as no update rather than as a phantom one.
      latestOffer = AvailableUpdate(
        version: ResolvedRelease.unknownVersion, channel: .latest, validator: validator
      )
    }

    state.recommendedUpdate = recommendedOffer
    state.latestUpdate = latestOffer
    try store.save(state)
    states[toolID] = state
    publish(toolID)

    // Notified for the recommended move only, or, for a tool with no recommendation at
    // all, for the one channel it has. Someone sitting on the tested version does not need
    // to be told every few weeks that the vendor shipped something nobody has tried.
    let update = recommendedOffer ?? (descriptor.recommended == nil ? latestOffer : nil)
    if let update {
      logger.info(
        "A newer build of a tool is available",
        metadata: [
          "tool": .string(toolID), "version": .string(update.version),
        ])
      await alerts?.raise(
        UserAlert(
          severity: .info,
          title: "\(descriptor.displayName) has an update",
          body: update.version == ResolvedRelease.unknownVersion
            ? "A newer build of \(descriptor.displayName) has been published. "
              + "Nothing has been changed; install it when it suits you."
            : update.channel == .recommended
              ? "\(descriptor.displayName) \(update.version) is now the "
                + "recommended version for this server; this Mac has "
                + "\(state.installed?.version ?? "an older build"). Nothing has "
                + "been changed; install it when it suits you."
              : "\(descriptor.displayName) \(update.version) is available; this "
                + "Mac has \(state.installed?.version ?? "an older build"). "
                + "Nothing has been changed; install it when it suits you.",
          source: "Programs",
          actions: [.installTool(id: toolID)],
          // Keyed by version, so a user who ignores one update is told about the
          // next one rather than being reminded about this one forever.
          dedupeKey: "tool.update.\(toolID).\(update.version)"
        )
      )
    }
    // The recommended move when there is one, since that is the actionable answer; the
    // vendor's newest otherwise.
    return recommendedOffer ?? latestOffer
  }

  /// Checks everything installed. Failures are logged, not thrown: one vendor being
  /// unreachable should not stop the others being checked.
  public func checkAllForUpdates() async {
    for toolID in descriptors.keys.sorted() {
      do {
        try await checkForUpdate(toolID)
      } catch {
        logger.debug(
          "Tool update check failed",
          metadata: [
            "tool": .string(toolID), "error": .string(String(describing: error)),
          ])
      }
    }
  }

  // MARK: Housekeeping

  /// Removes version directories that are neither current nor the one revert goes back to.
  ///
  /// Two copies is the ceiling. Keeping every version ever installed is 38 MB each for a
  /// capability (going back further than one step) that nobody uses and that a fresh
  /// install provides anyway.
  private func prune(toolID: String, state: ToolState) {
    let layout = store.layout(for: toolID)
    let keep = Set(
      [state.installed, state.previous].compactMap { build -> String? in
        build.map {
          layout.versionDirectory(version: $0.version, architecture: $0.architecture)
            .lastPathComponent
        }
      })
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: layout.versionsDirectory, includingPropertiesForKeys: nil
      )
    else { return }

    for entry in entries where !keep.contains(entry.lastPathComponent) {
      try? FileManager.default.removeItem(at: entry)
    }
    // Scratch space from an interrupted download, which the installer's own cleanup
    // cannot reach if the process died mid-install.
    try? FileManager.default.removeItem(at: layout.downloadsDirectory)
  }

  // MARK: Observation

  /// Status changes, for a UI that wants to follow a download rather than poll it.
  public func stream() -> AsyncStream<ToolStatus> {
    let id = UUID()
    return AsyncStream { continuation in
      observers[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeObserver(id) }
      }
    }
  }

  private func removeObserver(_ id: UUID) { observers[id] = nil }

  /// Which installs are running right now.
  ///
  /// Exists only so a late progress update can be told apart from a live one; see
  /// `noteInstallProgress`. Not a substitute for `ToolStatus.isBusy`, which is what
  /// refuses a second install of the same tool.
  private var installsInFlight: Set<String> = []

  /// A phase reported by a running install.
  ///
  /// Dropped when the install it belongs to has already finished. This check is what makes
  /// the progress hop safe to leave unstructured; awaiting each phase inside the installer
  /// instead would hold the actor across a download.
  private func noteInstallProgress(_ phase: ToolInstallPhase, for toolID: String) {
    guard installsInFlight.contains(toolID) else { return }
    set(activity: .installing(phase), for: toolID)
  }

  private func set(activity: ToolActivity, for toolID: String) {
    activities[toolID] = activity
    publish(toolID)
  }

  private func publish(_ toolID: String) {
    guard let status = status(of: toolID) else { return }
    for continuation in observers.values { continuation.yield(status) }
  }
}
