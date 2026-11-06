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
//  **It speaks up only about programs something is using.** Every tool any manifest declares
//  is registered, so the selected connection method's program sits beside five others nobody
//  chose. A scan still looks at all of them, because the Connection page shows what a method
//  would find before anyone picks it; but the scheduled update check and the notice that a
//  copy changed go only to tools an enabled service declares (`isInUse`). Without that, a
//  server on Custom URL is told its Tailscale is behind whenever a copy installed for another
//  method is still on disk. A person pressing Check on a tool's page is asking, and
//  is answered whatever is selected.
//
//  What the UI reads about a tool is `ToolStatus.swift`.
//
//  See `.claude/docs/performance.md` and TODO.md "Tunnel binaries".

import BBCore
import BBDiagnostics
import BBServiceKit
import Foundation
import Logging

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
  /// Whether some enabled service declares this tool: the selected connection method, or
  /// any other service that is switched on. Asked per check rather than captured, because
  /// changing the connection method writes a setting and restarts no part of this actor.
  private let isInUse: @Sendable (_ toolID: String) async -> Bool

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
    isInUse: @escaping @Sendable (_ toolID: String) async -> Bool = { _ in true },
    logger: Logger = Logger(label: "bluebubbles.tools")
  ) {
    self.discovery = discovery
    self.isInUse = isInUse
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
    // Every condition here is a license to run someone else's program that nobody chose:
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
    try beginOperation(on: toolID)
    defer { endOperation(on: toolID) }

    let pinnedTeamID = (states[toolID] ?? store.load(toolID)).pinnedTeamID
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
        pinnedTeamID: pinnedTeamID
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

      // Read AFTER the install, not before it: a choice the person made while it ran (a
      // preference, a copy of their own) is in the record now, and writing back what was
      // read thirty seconds ago would undo it.
      var state = states[toolID] ?? store.load(toolID)

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
      // Tolerated: the new build is already on disk and `current` points at it, so
      // refusing the record would leave this server describing a version it is no longer
      // running. See `commitTolerating`.
      await commitTolerating(state, for: toolID)
      prune(toolID: toolID, state: state)

      installsInFlight.remove(toolID)
      set(activity: .idle, for: toolID)
      return installed
    } catch {
      installsInFlight.remove(toolID)
      let description = DiagnosticText.sentence(for: error)
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
  public func revert(_ toolID: String) async throws {
    guard let descriptor = descriptors[toolID] else { throw ToolError.unknownTool(toolID) }
    try beginOperation(on: toolID)
    defer { endOperation(on: toolID) }
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
    //
    // Tolerated, for the same reason as an install: the link has already been repointed.
    await commitTolerating(state, for: toolID)
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
    // In the operation lane: this reads the record, waits on a probe, and writes it back.
    try beginOperation(on: toolID)
    defer { endOperation(on: toolID) }
    set(activity: .inspectingChosenCopy, for: toolID)
    defer { set(activity: .idle, for: toolID) }

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
    // The same file the scan recorded, asked again just now: the newer answer replaces the
    // older one. Otherwise the page says "using 1.104.4, which you chose" above "there is a
    // copy at that path that does not report a version", about one file.
    if state.discovered?.executablePath == path {
      state.discovered = probe
    }
    // Choosing a copy is the opposite of asking for a dedicated one, so it says so rather
    // than leaving a preference set that would ignore what was just chosen.
    state.preference = .automatic
    try commit(state, for: toolID)
    return probe
  }

  public func clearExternalBinary(for toolID: String) throws {
    guard descriptors[toolID] != nil else { throw ToolError.unknownTool(toolID) }
    var state = states[toolID] ?? store.load(toolID)
    state.externalPath = nil
    state.externalProbe = nil
    try commit(state, for: toolID)
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
    try commit(state, for: toolID)
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
  /// and answered with a version is not probed again, so after the first run this is a
  /// handful of `stat` calls. The probe happens on a first run, a fresh install, a
  /// `brew upgrade`, and for a copy whose last answer refused it (`ProbedCopy.isSettled`).
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
    let outcomes = await withTaskGroup(of: ScanOutcome?.self) { group in
      for (descriptor, state) in work {
        group.addTask {
          await Self.scan(descriptor, state: state, discovery: discovery, reprobing: false)
        }
      }
      var collected: [ScanOutcome] = []
      for await outcome in group {
        if let outcome { collected.append(outcome) }
      }
      return collected
    }
    for outcome in outcomes { await apply(outcome) }
  }

  /// One tool, for the button that says Check Again.
  ///
  /// **Probes again even when the file has not changed**, which no other scan does. Someone
  /// pressing this is saying the page is wrong about what is here, and the one answer the
  /// fingerprint cache cannot give is a different verdict on the same file: a probe that
  /// timed out while macOS assessed a binary it had not seen before is exactly that, and
  /// without this the button looked at the record, found it current, and changed nothing.
  ///
  /// In the operation lane, so it cannot interleave with an install that read the record
  /// before a download, and it says what it is doing while the probe runs, because a probe
  /// can take its whole timeout and a button that shows nothing for ten seconds reads as
  /// broken.
  public func scanForExistingCopy(_ toolID: String) async {
    guard let descriptor = descriptors[toolID], descriptor.acceptsPreexistingCopies else {
      return
    }
    // Busy means an install, revert or check is running and the buttons are disabled; the
    // install will publish its own outcome, and the next press looks again.
    guard (try? beginOperation(on: toolID)) != nil else { return }
    defer { endOperation(on: toolID) }
    set(activity: .lookingOnThisMac, for: toolID)
    defer { set(activity: .idle, for: toolID) }

    let state = states[toolID] ?? store.load(toolID)
    guard
      let outcome = await Self.scan(
        descriptor, state: state, discovery: discovery, reprobing: true)
    else { return }
    await apply(outcome)
  }

  /// Off the actor: the part that spawns processes.
  ///
  /// Nil when the scan was cancelled part-way. Nothing is recorded then, deliberately: the
  /// records are trusted until the file changes, so writing what an interrupted probe said
  /// would make it the permanent answer. See `ToolVersionProbe`.
  private static func scan(
    _ descriptor: ManagedToolDescriptor, state: ToolState, discovery: ToolDiscovery,
    reprobing: Bool
  ) async -> ScanOutcome? {
    var external = state.externalProbe
    if let path = state.externalPath, reprobing || external?.isSettled != true {
      do {
        external = try await discovery.inspect(path, as: descriptor)
      } catch is CancellationError {
        return nil
      } catch {
        // A refusal here is not thrown away: the copy stays in use and the drift alert
        // below is what says something changed. Silently dropping a path a person chose
        // would be overriding them.
        external = nil
      }
    }
    var found = state.discovered
    if reprobing || found?.isSettled != true {
      do {
        found = try await discovery.find(descriptor)
      } catch {
        return nil
      }
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
    // Tolerated: the scan is an observation, and losing the record costs a re-probe next
    // launch, not the use of a copy that was found.
    await commitTolerating(state, for: outcome.toolID)
    let after = resolve(descriptor: descriptor, state: state)

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
  ///
  /// Silent for a tool nothing enabled declares. The change is still recorded, so the
  /// tool's page says the same thing, and choosing the method later is refused with its
  /// own notice if the copy will not do.
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

    guard let body, await isInUse(descriptor.id) else { return }
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
    let recorded = states[toolID] ?? store.load(toolID)
    let installed = recorded.installed
    // Nothing installed means nothing to update: "install" is the offer, and reporting
    // an available update for something absent would be a notification with no meaning.
    guard installed != nil else { return nil }

    // In the same lane as an install. The check used to mark itself busy and then idle in
    // a `defer`, and the idle landed in the middle of an install that had started since,
    // which reopened the gate a second install was refused by.
    try beginOperation(on: toolID)
    defer { endOperation(on: toolID) }
    set(activity: .checking, for: toolID)
    defer { set(activity: .idle, for: toolID) }

    let installedVersion = SemanticVersion(installed?.version ?? "0")
    let checkedAt = Date()

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
    } else if let validator = release.validator, validator != recorded.lastValidator {
      // No version to compare, so the question is whether the bytes at the URL are the
      // ones we installed from. A vendor that sends no validator leaves this nil, and
      // "cannot tell" is reported as no update rather than as a phantom one.
      latestOffer = AvailableUpdate(
        version: ResolvedRelease.unknownVersion, channel: .latest, validator: validator
      )
    }

    // Only the fields the check owns, onto the record as it is NOW, for the reason
    // `install` reads it again after its own wait.
    var state = states[toolID] ?? store.load(toolID)
    state.lastCheckedAt = checkedAt
    state.recommendedUpdate = recommendedOffer
    state.latestUpdate = latestOffer
    // Tolerated: the check succeeded, and what an unsaved record loses is only the offer
    // and when it was looked for, which the next check finds again.
    await commitTolerating(state, for: toolID)

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

  /// Checks everything installed that an enabled service uses. Failures are logged, not
  /// thrown: one vendor being unreachable should not stop the others being checked.
  ///
  /// A tool nothing enabled declares is skipped outright: no request to its vendor and no
  /// notice. A dedicated copy outlives the method it was installed for, and telling someone
  /// on Custom URL that their Tailscale has an update is a notice about a program the server
  /// is not running. Its page's Check button still asks, through `checkForUpdate(_:)`.
  public func checkAllForUpdates() async {
    for toolID in descriptors.keys.sorted() {
      guard await isInUse(toolID) else { continue }
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

  // MARK: Recording

  // Every change to a tool's record is saved, kept and published through one of the two
  // doors below, and which one is the decision about a failed save, made where the change
  // is. Spelled out by hand at each site, a `try store.save` and a `do`/`catch` around one
  // read as style rather than policy, and nothing says which was meant.
  // `ToolRecordPolicyTests` refuses a save outside the doors.

  /// For a change whose record IS the change: a person's choice, which nothing else
  /// carries. A failed save throws and memory is left as it was, so the person is told at
  /// the moment they chose rather than finding the choice gone after a restart.
  private func commit(_ state: ToolState, for toolID: String) throws {
    try store.save(state)
    keep(state, for: toolID)
  }

  /// For a change that has already happened on disk, or that is an observation. A failed
  /// save is reported and the state kept anyway, because refusing it would leave this
  /// server describing something other than what it is running.
  private func commitTolerating(_ state: ToolState, for toolID: String) async {
    do {
      try store.save(state)
    } catch {
      await reportUnsaved(toolID, error: error)
    }
    keep(state, for: toolID)
  }

  private func keep(_ state: ToolState, for toolID: String) {
    states[toolID] = state
    publish(toolID)
  }

  /// The tolerated case, which is never silent.
  private func reportUnsaved(_ toolID: String, error: any Error) async {
    let name = descriptors[toolID]?.displayName ?? toolID
    logger.warning(
      "Could not save a program's record; keeping it in memory",
      metadata: [
        "tool": .string(toolID), "error": .string(String(describing: error)),
      ])
    await alerts?.raise(
      UserAlert(
        severity: .warning,
        title: "Could not save the record for \(name)",
        body: "BlueBubbles is using \(name) as shown, but could not save what it knows about "
          + "it, so it will not remember this after a restart. "
          + DiagnosticText.sentence(for: error),
        source: "Programs",
        diagnostics: Diagnostics(
          domain: "tools",
          underlyingDescription: String(describing: error),
          context: ["tool": .string(toolID)]
        ),
        dedupeKey: "tool.record-unsaved.\(toolID)"
      )
    )
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
  /// `noteInstallProgress`. Not the gate: `operationsInFlight` is.
  private var installsInFlight: Set<String> = []

  /// The one long operation each tool may have running: an install, a revert or an update
  /// check.
  ///
  /// Its own set rather than `ToolStatus.isBusy`, because the activity that reads is
  /// PRESENTATION: an update check set it idle in a `defer` while an install that had
  /// started since was still downloading, and a second install then passed the gate and
  /// adopted into the same version directory as the first. Each of the three also read the
  /// record before a long wait and wrote it back after, so running two at once lost one.
  private var operationsInFlight: Set<String> = []

  private func beginOperation(on toolID: String) throws {
    guard operationsInFlight.insert(toolID).inserted else {
      throw ToolError.busy(tool: toolID)
    }
  }

  private func endOperation(on toolID: String) {
    operationsInFlight.remove(toolID)
  }

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
