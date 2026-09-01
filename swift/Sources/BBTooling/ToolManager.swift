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
//  unimplemented feature.** The tool being updated is, for most installs, the tunnel — the
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
  /// A binary the user pointed at — an offline install, or a Homebrew copy.
  case external
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

public struct ToolStatus: Sendable, Equatable, Identifiable {
  public let descriptor: ManagedToolDescriptor
  public let state: ToolState
  public let activity: ToolActivity
  public let origin: ToolOrigin
  /// What a service would actually be handed right now.
  public let executablePath: String?

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
  /// A newer recommended version — the offer worth acting on.
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
  /// The bundled fallback. A closure so this module needs to know nothing about app bundles
  /// — and so a test can supply one without one existing.
  private let bundledLocator: @Sendable (String) -> String?

  private var descriptors: [String: ManagedToolDescriptor] = [:]
  private var states: [String: ToolState] = [:]
  private var activities: [String: ToolActivity] = [:]
  private var observers: [UUID: AsyncStream<ToolStatus>.Continuation] = [:]

  public init(
    store: ToolStore = ToolStore(),
    transport: any ToolTransport = URLSessionToolTransport(),
    alerts: (any AlertRaising)? = nil,
    bundledLocator: @escaping @Sendable (String) -> String? = { _ in nil },
    logger: Logger = Logger(label: "bluebubbles.tools")
  ) {
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
  /// alternative — refusing the second — would mean a plugin could deny a built-in service
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
      executablePath: resolution.path
    )
  }

  /// The executable a service should run, or nil.
  ///
  /// Nil is a real answer with a real remedy attached — see the alert the proxy services
  /// raise — rather than something to paper over with a guess at a path.
  public func executablePath(for toolID: String) -> String? {
    guard let descriptor = descriptors[toolID] else { return nil }
    return resolve(descriptor: descriptor, state: states[toolID] ?? store.load(toolID)).path
  }

  /// Preference order: what the user chose, then what we manage, then what shipped.
  ///
  /// The user's own choice wins over a managed install because pointing at a binary is an
  /// explicit act — someone who has done it is working around something, and silently
  /// preferring our download would undo the workaround without saying so.
  private func resolve(
    descriptor: ManagedToolDescriptor, state: ToolState
  ) -> (path: String?, origin: ToolOrigin) {
    if let external = state.externalPath,
      FileManager.default.isExecutableFile(atPath: external)
    {
      return (external, .external)
    }
    if let installed = state.installed,
      FileManager.default.isExecutableFile(atPath: installed.executablePath)
    {
      return (installed.executablePath, .managed)
    }
    if let bundled = bundledLocator(descriptor.executableName) {
      return (bundled, .bundled)
    }
    return (nil, .missing)
  }

  // MARK: Installing

  /// Installs, or reinstalls, the current build.
  ///
  /// The same call is "install" and "update" on purpose: they are the same operation, and
  /// having two would invite them to diverge in exactly the step that keeps the old version
  /// around.
  ///
  /// Defaults to the RECOMMENDED channel — the version the declaring plugin was tested
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
        Task { [weak self] in await self?.set(activity: .installing(phase), for: toolID) }
      }

      // The version being replaced becomes the one revert goes back to — unless it IS
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

      set(activity: .idle, for: toolID)
      return installed
    } catch {
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
    // The update that was just backed out is still available, and saying so is honest —
    // the user may have reverted to wait for a fix rather than to refuse it forever.
    try store.save(state)
    states[toolID] = state
    publish(toolID)
  }

  /// Uses a binary the user already has.
  ///
  /// The offline path. Someone setting up a tunnel may have no working connection — that is
  /// frequently why they are setting up a tunnel — and "download it" cannot be the only way
  /// to have one. It also covers a Homebrew install, which many users already have.
  public func adoptExternalBinary(at path: String, for toolID: String) throws {
    guard descriptors[toolID] != nil else { throw ToolError.unknownTool(toolID) }
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw ToolError.externalBinaryUnusable(
        path: path, reason: "it is not an executable file"
      )
    }
    var state = states[toolID] ?? store.load(toolID)
    state.externalPath = path
    try store.save(state)
    states[toolID] = state
    publish(toolID)
  }

  public func clearExternalBinary(for toolID: String) throws {
    guard descriptors[toolID] != nil else { throw ToolError.unknownTool(toolID) }
    var state = states[toolID] ?? store.load(toolID)
    state.externalPath = nil
    try store.save(state)
    states[toolID] = state
    publish(toolID)
  }

  // MARK: Update checks

  /// Asks the vendor what is current. Never installs anything.
  @discardableResult
  public func checkForUpdate(_ toolID: String) async throws -> AvailableUpdate? {
    guard let descriptor = descriptors[toolID] else { throw ToolError.unknownTool(toolID) }
    var state = states[toolID] ?? store.load(toolID)
    // Nothing installed means nothing to update — "install" is the offer, and reporting
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
    // weaker claim — nobody here has run it — so it is recorded and shown, and never
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

    // Notified for the recommended move only — or, for a tool with no recommendation at
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
              + "Nothing has been changed — install it when it suits you."
            : update.channel == .recommended
              ? "\(descriptor.displayName) \(update.version) is now the "
                + "recommended version for this server; this Mac has "
                + "\(state.installed?.version ?? "an older build"). Nothing has "
                + "been changed — install it when it suits you."
              : "\(descriptor.displayName) \(update.version) is available; this "
                + "Mac has \(state.installed?.version ?? "an older build"). "
                + "Nothing has been changed — install it when it suits you.",
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
  /// capability — going back further than one step — that nobody uses and that a fresh
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

  private func set(activity: ToolActivity, for toolID: String) {
    activities[toolID] = activity
    publish(toolID)
  }

  private func publish(_ toolID: String) {
    guard let status = status(of: toolID) else { return }
    for continuation in observers.values { continuation.yield(status) }
  }
}
