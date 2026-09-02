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
    "rate_limit_enabled", "rate_limit_failures", "rate_limit_block_seconds",
    "trust_local_network", "trusted_proxies",
    // Owned by the logging system, which is process-wide and older than any service.
    "log_level",
  ]

  /// Settings read once while the server is being ASSEMBLED, before any service exists.
  ///
  /// These configure objects that services are HANDED rather than objects services own — the
  /// route table, the socket's codec negotiator, the token auth service. Adding them to a
  /// service's `watchedSettings` would restart that service and hand it the same object it
  /// had before, which looks like wiring and is not; only rebuilding the composition
  /// actually applies them.
  ///
  /// So rather than pretend, the change raises a notice with a one-click restart. That is
  /// strictly better than the previous behaviour — saving the value and carrying on as
  /// though nothing had happened, which from outside is indistinguishable from a setting
  /// that was never wired up at all.
  /// Feature flags belong here too: they decide which route GROUPS are mounted, and that
  /// happens once while the router is built. Toggling one has to raise the restart notice
  /// for the same reason `additive_endpoints` does — writing the value and carrying on
  /// would leave a switch that reads as on and does nothing.
  static let structuralKeys: Set<String> = Set(
    // `facetime_incoming_handoff` decides whether a ROUTE GROUP mounts, which is settled
    // when the composition is assembled — so it raises the restart notice rather than
    // being watched by a service that could not apply it anyway.
    // `chat_db_readers` decides what KIND of connection chat.db is opened with, and that
    // happens once in `ServerComposition.build`. No service can apply it — the repository
    // and every interface hold the handle that already exists — so it raises the restart
    // notice like the rest of this list.
    [
      "auth_mode", "additive_endpoints", "event_payload_codec", "facetime_incoming_handoff",
      "chat_db_readers",
    ]
      + Features.allKeys
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
    if change.changedKeys.contains("server_address") {
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
