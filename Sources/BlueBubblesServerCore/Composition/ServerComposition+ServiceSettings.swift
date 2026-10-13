//  ServerComposition+ServiceSettings
//  What runs before anything is built: the install gate, and each service's settings.
//
//  In this window because a service that reads its settings before they are migrated
//  configures itself from the old shape and never looks again. The manifest validator runs
//  here too, and its verdict is carried to registration: a refused service, and everything
//  that depends on it, is never registered, so a manifest declared invalid cannot run.

import BBBuiltIns
import BBCore
import BBServiceKit
import BBSettings
import Logging

extension ServerComposition {

  // MARK: - Before anything is built

  /// Refuses to build on an unadopted Electron install. This does NOT migrate.
  ///
  /// Migrating automatically would rewrite a user's settings and move their credentials with
  /// no notice and no way to decline, and redoing a settings import is not harmless: it
  /// writes every key it finds with no comparison and reverts anything changed since.
  ///
  /// Building on defaults instead would be worse still (a different port, no password)
  /// so the answer is to refuse and say so. `bluebubbles-server --migrate` adopts it; the
  /// app presents a wizard. Certificates are deliberately NOT in the blocking set: see
  /// `MigrationStep.isBlocking`.
  static func refuseUnadoptedInstall(settings: SettingsStore) async throws {
    if let refusal = await MigrationStateStore.status(in: settings).refusal { throw refusal }
  }

  /// Runs each service's own settings migrations.
  ///
  /// In the same window and for the same reason as the install gate above: a service that
  /// reads its settings before they have been moved configures itself from the old shape
  /// and never looks again.
  ///
  /// Validated BEFORE migrations run, because a migration is described by the same
  /// manifest: applying one from a manifest that has not been checked would be acting on
  /// untrusted instructions about where someone's data should go.
  /// - Returns: the services the validator REFUSED, so registration can skip them.
  ///
  ///   Returning them is the point. If the verdict reached only `prepare` while
  ///   `registerServices` registered every service, a FATAL manifest problem (an entitlement
  ///   naming a secret, a tool with no checksum) would be logged and the service would run
  ///   anyway. A validator whose verdict nothing acts on is a log line, and the same manifests and the same validator are meant to be the boundary
  ///   for third-party plugins.
  static func prepareServiceSettings(
    settings: SettingsStore, logger: Logger
  ) async -> Set<ServiceIdentifier> {
    await seedDisabledServices(settings: settings, logger: logger)
    let validated = await ServiceSettingsBridge.validate(
      manifests: BuiltInManifests.all,
      enabled: await enabledServices(settings: settings),
      logger: logger,
      // No alert centre yet: it is constructed further down, after storage. A conflict
      // found here is logged and re-raised once the centre exists rather than being
      // dropped; see `SettingsPropagation`, which re-validates on a settings change.
      alerts: nil
    )
    await ServiceSettingsBridge.prepare(
      manifests: validated, store: settings, logger: logger
    )
    await adoptLegacyNtfySettings(settings: settings, logger: logger)
    let kept = Set(validated.map(\.id))
    let refused = Set(BuiltInManifests.all.map(\.id)).subtracting(kept)
    return withDependents(of: refused, logger: logger)
  }

  /// Moves the core `ntfy_*` settings an older install had into the ntfy integration, once.
  /// Here rather than in `NtfyDeliveryService.start`; see `NtfySettingsAdoption`.
  static func adoptLegacyNtfySettings(settings: SettingsStore, logger: Logger) async {
    let ntfy = BuiltInManifests.ntfy
    do {
      let adopted = try await AuditContext.acting(as: .system(component: ntfy.id.rawValue)) {
        try await NtfySettingsAdoption.run(store: settings, manifest: ntfy)
      }
      // Named at `info` because it moved somebody's configuration: a support log for a
      // server whose ntfy suddenly looks different needs to say this ran. Neither the topic
      // nor the token is in the line: the topic is a shared secret by design, and the token
      // is a credential.
      if adopted { logger.info("Adopted the previous ntfy settings into the ntfy integration") }
    } catch {
      // Not fatal: the old keys are cleared only after the new ones are written, so a
      // failure leaves the previous configuration where it was and the next start retries.
      logger.error(
        "Could not adopt the previous ntfy settings; retrying on the next start",
        metadata: ["error": .string(DiagnosticText.sentence(for: error))])
    }
  }

  /// A refusal, closed over everything that depends on it.
  ///
  /// **Refusing a leaf is safe; refusing a dependency was not.** A refused service is not
  /// registered at all, which is the point — the registry cannot start what it does not know
  /// about. But `resolveStartOrder()` throws `unknownDependency` when a registered service
  /// names one that is absent, and sixteen built-in manifests declare a dependency on the
  /// HTTP service. So refusing that one manifest took the whole server down with it: nothing
  /// started, which is the exact opposite of the first property `ServerComposition`'s header
  /// claims, that the server starts even when things are wrong.
  ///
  /// The existing refusal test only ever refused a leaf, so the case was invisible. It bites
  /// third-party manifests first, and any future built-in that fails validation.
  ///
  /// Transitive, and computed to a fixed point: refusing HTTP refuses the socket, and
  /// refusing the socket refuses anything that named the socket.
  static func withDependents(
    of refused: Set<ServiceIdentifier>, logger: Logger
  ) -> Set<ServiceIdentifier> {
    guard !refused.isEmpty else { return refused }
    var closed = refused
    var changed = true
    while changed {
      changed = false
      for manifest in BuiltInManifests.all where !closed.contains(manifest.id) {
        guard manifest.dependencies.contains(where: closed.contains) else { continue }
        closed.insert(manifest.id)
        changed = true
        logger.warning(
          "Refusing a service because something it depends on was refused",
          metadata: [
            "service": .string(manifest.id.rawValue),
            "dependencies": .string(
              manifest.dependencies.filter(closed.contains).map(\.rawValue)
                .sorted().joined(separator: ", ")),
          ])
      }
    }
    return closed
  }

  /// Writes the default set of switched-off services, once, on an install that has never
  /// had one; and on an install that has, adds each switched-off-by-default service it has
  /// never seen.
  ///
  /// Guarded on the key being ABSENT rather than empty: an empty `disabled_services` is a
  /// real answer — somebody switched everything on — and re-seeding over it would turn ntfy
  /// back off under them. `--set disabled_services=…` counts as present for the same reason,
  /// so a run started with an override is never seeded on top of.
  ///
  /// The second half is what makes "ships switched off" true on an UPGRADE. Without it a
  /// service added to `disabledByDefault` after an install was seeded is simply not in that
  /// install's list, and so comes up running on the first start after the upgrade. "Never
  /// seen" is the service's `__version` stamp being absent, which `ServiceSettingsBridge.prepare`
  /// writes for every manifest on the first start that knows it, enabled or not, and which
  /// this runs before. So the amendment happens once per service per install, and a person
  /// who later switches the service on is never switched back off. It amends the STORED
  /// list, never an override, so a `--set` run does not persist what it was told.
  ///
  /// The evidence that ntfy is already IN USE is its topic, in either place it can live: the
  /// integration's own field, or the core `ntfy_topic` an install had before ntfy was an
  /// integration. Seeding a working ntfy off during an upgrade is the one outcome this must
  /// not have, and it is invisible when it happens — notifications simply stop.
  static func seedDisabledServices(settings: SettingsStore, logger: Logger) async {
    let inUse = await servicesAlreadyInUse(settings: settings)
    guard await settings.string(forKey: Settings.disabledServicesKey) == nil else {
      await disableServicesNewToThisInstall(settings: settings, inUse: inUse, logger: logger)
      return
    }

    let seeded = ServiceEnablement.seed(skipping: inUse)
    // Written even when EMPTY, because the write is what records that the seed has run: a
    // skipped write would leave the key absent and seed again on the next start, after the
    // user had switched something on.
    do {
      try await settings.set(
        ServiceEnablement.serialized(seeded),
        forKey: Settings.disabledServicesKey,
        isSecret: false
      )
      guard !seeded.isEmpty else { return }
      logger.info(
        "Seeded the services that ship switched off",
        metadata: ["services": .string(seeded.sorted().joined(separator: ", "))])
    } catch {
      // Not fatal, and not silent. Everything runs this start, which is the pre-seed
      // behaviour rather than a broken one, and the next start tries again.
      logger.error(
        "Could not seed the default service list",
        metadata: ["error": .string(DiagnosticText.sentence(for: error))])
    }
  }

  /// Adds to the stored list each switched-off-by-default service this install has never
  /// prepared. See `seedDisabledServices`.
  private static func disableServicesNewToThisInstall(
    settings: SettingsStore, inUse: Set<ServiceIdentifier>, logger: Logger
  ) async {
    // The stored list only: nothing stored means the key is an override, and an override is
    // this run's business, not the install's.
    guard let stored = await settings.persistedString(forKey: Settings.disabledServicesKey)
    else { return }

    var unseen: Set<ServiceIdentifier> = []
    for manifest in BuiltInManifests.all
    where BuiltInManifests.disabledByDefault.contains(manifest.id) {
      let stamp = await settings.string(forKey: ServiceMigrator.versionKey(for: manifest))
      if stamp == nil { unseen.insert(manifest.id) }
    }
    let disabled = ServiceEnablement.disabledIdentifiers(in: stored)
    let added = Set(unseen.subtracting(inUse).map(\.rawValue)).subtracting(disabled)
    guard !added.isEmpty else { return }

    do {
      try await settings.set(
        ServiceEnablement.serialized(disabled.union(added)),
        forKey: Settings.disabledServicesKey,
        isSecret: false
      )
      logger.info(
        "Switched off services this install had not seen, which ship switched off",
        metadata: ["services": .string(added.sorted().joined(separator: ", "))])
    } catch {
      // The service's version is stamped later in this start whatever happens here, so a
      // failed write is not retried: say so at the level that gets read.
      logger.error(
        "Could not switch off a service that ships switched off; it runs until switched off",
        metadata: [
          "services": .string(added.sorted().joined(separator: ", ")),
          "error": .string(DiagnosticText.sentence(for: error)),
        ])
    }
  }

  /// Services this install is evidently already using, so a default must not switch them
  /// off. The evidence that ntfy is IN USE is its topic, in either place it can live.
  private static func servicesAlreadyInUse(settings: SettingsStore) async
    -> Set<ServiceIdentifier>
  {
    var inUse: Set<ServiceIdentifier> = []
    let ntfy = BuiltInManifests.ntfy
    let configuredTopic =
      await settings.string(forKey: ntfy.storageKey(for: NtfySettingsAdoption.Field.topic)) ?? ""
    let legacyTopic = await settings.string(forKey: Settings.ntfyTopic.key) ?? ""
    if !configuredTopic.trimmingCharacters(in: .whitespaces).isEmpty
      || !legacyTopic.trimmingCharacters(in: .whitespaces).isEmpty
    {
      inUse.insert(ntfy.id)
    }
    return inUse
  }

  /// Which services count as ON, for the validator's exclusivity rule.
  ///
  /// Everything the user has not switched off, MINUS the connection methods that were not
  /// selected. Not the selected method alone: that would make the "two connection methods
  /// are enabled" rule unreachable, because the rule looks for two enabled members of one
  /// exclusive category, and a one-element set has no two of anything.
  ///
  /// With the built-in methods alone it is unreachable anyway, and honestly so: the
  /// selection is one setting, so two built-in methods cannot both be on. It becomes
  /// reachable when a third-party method joins the category, which is the case the
  /// validator exists for.
  static func enabledServices(settings: SettingsStore) async -> Set<ServiceIdentifier> {
    let selected = ServiceIdentifier(await settings.get(Settings.connectionMethod))
    let raw = await settings.string(forKey: Settings.disabledServicesKey) ?? ""
    // `ServiceEnablement` already owns the parse and the always-on exemptions; a second
    // reading of the same setting here is how the two would come to disagree.
    let disabled = ServiceEnablement.disabledIdentifiers(in: raw)
    var enabled: Set<ServiceIdentifier> = []
    for manifest in BuiltInManifests.all {
      if manifest.category == .reverseProxy {
        if manifest.id == selected { enabled.insert(manifest.id) }
      } else if ServiceEnablement.isEnabled(manifest.id, disabled: disabled) {
        enabled.insert(manifest.id)
      }
    }
    return enabled
  }
}
