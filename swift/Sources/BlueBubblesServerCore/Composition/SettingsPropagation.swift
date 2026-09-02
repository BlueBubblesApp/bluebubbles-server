//  SettingsPropagation
//  The wire between a settings write and the services that have to react to it.
//
//  `SettingsStore.write` emits ONE `SettingsChange` per batch and `ServiceRegistry.apply`
//  knows how to route it, restart the services that ask for it, and cascade to their
//  dependents. Until this existed, nothing connected the two: every `ConfigurableService`
//  declared `watchedSettings` and implemented `apply(_:)`, and none of it was ever called —
//  so changing the port, the proxy provider, or the Private API toggle in the UI did nothing
//  at all until the next launch, silently.
//
//  Two jobs, and they are deliberately separate:
//
//    1. Route the change to the registry. That is the whole of what `handleConfigUpdate`
//       (`index.ts:995-1153`) did, minus the 160-line if-chain.
//    2. Apply the changes that belong to no service. `AccessControlService` is shared by the
//       HTTP middleware and the socket rather than owned by either, so it is not in the
//       registry and would otherwise never see a policy change.
//
//  See `.claude/docs/architecture.md`.

import BBAuth
import BBDiagnostics
import BBInterfaces
import BBServiceKit
import BBSettings
import Foundation
import Logging

/// Consumes the settings change stream for the lifetime of a running server.
public actor SettingsPropagation {

  private let settings: SettingsStore
  private let registry: any SettingsChangeRouting
  private let accessControl: AccessControlService
  /// Called when the server's own address changes, with the new value.
  ///
  /// A closure rather than a reference to the context so this type stays constructible in a
  /// test without a whole server behind it — which is what lets the wiring test assert that
  /// a `server_address` write reaches an announcement at all.
  private let onServerAddressChanged: @Sendable (String) async -> Void
  /// Called with the structural keys that changed, so the composition root can tell the user.
  private let onRestartRequired: @Sendable (Set<String>) async -> Void
  /// Cleared when `password` is written. Optional so the propagation stays constructible in
  /// a test that has no auth stack behind it.
  private let passwordDigests: PasswordDigestCache?
  private let logger: Logger
  private var pump: Task<Void, Never>?

  /// Keys that are applied here rather than by a service, because no single service owns
  /// the object they configure. `AccessControlService` is shared by the HTTP middleware and
  /// the socket handshake, so it belongs to neither and is not in the registry.
  static let unownedKeys: Set<String> = [
    Settings.rateLimitEnabled.key, Settings.rateLimitFailureThreshold.key,
    Settings.rateLimitBlockSeconds.key, Settings.trustLocalNetwork.key,
    Settings.trustedProxies.key,
    // Owned by the logging system, which is process-wide and older than any service.
    Settings.logLevel.key,
  ]

  /// Settings read once while the server is being ASSEMBLED, before any service exists.
  ///
  /// These configure objects that services are HANDED rather than objects services own — the
  /// route table, the socket's codec negotiator, the token auth service, the chat.db handle.
  /// Adding them to a service's `watchedSettings` would restart that service and hand it the
  /// same object it had before, which looks like wiring and is not; only rebuilding the
  /// composition actually applies them. So the change raises a notice with a one-click
  /// restart instead.
  ///
  /// DERIVED from the declarations: a setting says `application: .composition` on itself,
  /// and this is every setting that does. A new composition-time setting reaches the restart
  /// notice by being declared, and a list here that could disagree with the declaration is
  /// exactly what this used to be.
  static let structuralKeys: Set<String> = Set(
    Settings.all.filter { $0.application == .composition }.map(\.key)
  )

  public init(
    settings: SettingsStore,
    registry: any SettingsChangeRouting,
    accessControl: AccessControlService,
    onServerAddressChanged: @escaping @Sendable (String) async -> Void = { _ in },
    onRestartRequired: @escaping @Sendable (Set<String>) async -> Void = { _ in },
    passwordDigests: PasswordDigestCache? = nil,
    logger: Logger = Logger(label: "bluebubbles.settings.propagation")
  ) {
    self.settings = settings
    self.registry = registry
    self.accessControl = accessControl
    self.onServerAddressChanged = onServerAddressChanged
    self.onRestartRequired = onRestartRequired
    self.passwordDigests = passwordDigests
    self.logger = logger
  }

  public var isRunning: Bool { pump != nil }

  /// Subscribes before the caller's first write, so a change made during startup is not
  /// missed. Idempotent: starting twice does not open a second subscription.
  public func start() async {
    guard pump == nil else { return }

    // Taken here rather than inside the task: `changes()` registers the continuation,
    // and doing that inside a spawned task leaves a window where a write lands before
    // anyone is listening.
    let stream = await settings.changes()

    pump = Task { [weak self] in
      for await change in stream {
        guard let self else { return }
        await self.handle(change)
      }
    }
  }

  public func stop() {
    pump?.cancel()
    pump = nil
  }

  /// Exposed so a test can drive one change without racing the stream.
  func handle(_ change: SettingsChange) async {
    logger.info(
      "Settings changed",
      metadata: [
        "keys": .string(change.changedKeys.sorted().joined(separator: ", "))
      ])

    // FIRST, before anything that can suspend for long or throw. The cached digest is
    // the only copy of the password the auth path consults, so a window where it is stale
    // is a window where a password the user has just revoked still works.
    if change.changedKeys.contains(Settings.password.key) {
      await passwordDigests?.invalidate()
    }

    if change.intersects(Self.unownedKeys) {
      await applyUnowned()
    }

    if change.intersects(Self.structuralKeys) {
      await announceRestartNeeded(change.changedKeys.intersection(Self.structuralKeys))
    }

    // Handled here rather than by a service, for the reason the section above gives: the
    // announcement belongs to no single service. It reaches the socket AND Firebase, and
    // a socket-only install — no Firebase at all — still has to tell its connected
    // clients where the server moved to. Hanging it off the push service would mean the
    // event stopped being emitted on exactly the installs that have no other route.
    if change.changedKeys.contains(Settings.serverAddress.key) {
      await onServerAddressChanged(await settings.get(Settings.serverAddress))
    }

    await registry.apply(change)
  }

  private func announceRestartNeeded(_ keys: Set<String>) async {
    logger.info(
      "A setting changed that only applies on restart",
      metadata: [
        "keys": .string(keys.sorted().joined(separator: ", "))
      ])
    await onRestartRequired(keys)
  }

  private func applyUnowned() async {
    // Takes effect on loggers that already exist, so a user who raises the level while
    // reproducing a problem sees the extra lines for the rest of that attempt.
    LoggingSystemBootstrap.setLevel(
      Settings.logLevel(from: await settings.get(Settings.logLevel))
    )
    await accessControl.update(policy: ServerComposition.accessPolicy(from: settings))
    await accessControl.update(trust: ServerComposition.proxyTrust(from: settings))
    await accessControl.trustLocalNetwork(await settings.get(Settings.trustLocalNetwork))
  }
}
