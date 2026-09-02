//  ServiceSettingsBridge
//  Where a manifest's declarations meet the real settings store.
//
//  Two jobs, both of which have to happen before any service reads a setting:
//
//    1. Run each service's migrations, so a service whose fields were renamed in an update
//       finds its configuration where it now expects it rather than reporting itself
//       unconfigured while the value sits under the old key.
//    2. Seed declared defaults, so a field with a `setDefault`-free first install still has
//       the value its manifest says it should.
//
//  Ordered before the registry starts anything, for the same reason the legacy import is:
//  migrating after a service has read its settings means it configured itself from the old
//  shape and will not look again.
//
//  See `.claude/docs/architecture.md`.

import BBDiagnostics
import BBInterfaces
import BBServiceKit
import BBSettings
import Foundation
import Logging

/// Adapts `SettingsStore` to what a migration needs.
///
/// A thin conformance rather than putting the protocol on the store itself: `BBServiceKit`
/// must not depend on `BBSettings`, so the two meet here, in the composition root, which is
/// the layer that is allowed to know about both.
struct SettingsStorageAdapter: MigratableStorage {
  let store: SettingsStore

  func value(forKey key: String) async -> String? {
    await store.string(forKey: key)
  }

  func setValue(_ value: String?, forKey key: String, isSecret: Bool) async {
    // A nil clears the key. `setDynamic` with an empty string is the store's way of saying
    // "no value", which reads back as nil through `string(forKey:)`.
    try? await store.set(value ?? "", forKey: key, isSecret: isSecret)
  }
}

public enum ServiceSettingsBridge {

  /// Checks every manifest before anything it describes is allowed to run.
  ///
  /// Third-party manifests MUST be validated — they are the untrusted input the validator
  /// exists for. Core manifests are validated too, and the reason is cost rather than
  /// suspicion: the whole pass is a few hundred string comparisons over sixteen manifests,
  /// far below the noise floor of opening a database, and skipping it would mean the rules
  /// that protect users from plugins are never exercised on the code path that actually
  /// ships. A built-in that violates them is a bug we would rather find at launch than
  /// discover when a plugin author copies it as an example.
  ///
  /// Fatal problems are reported and the service is refused; a category conflict is
  /// reported and honoured, because "you have two connection methods selected" is a state a
  /// user can be in and be asked to fix, not a reason to refuse to boot.
  ///
  /// - Returns: The manifests that may be started.
  @discardableResult
  static func validate(
    manifests: [ServiceManifest],
    enabled: Set<ServiceIdentifier>,
    logger: Logger,
    alerts: AlertCenter?
  ) async -> [ServiceManifest] {
    let problems = ManifestValidator.validate(
      all: manifests,
      secretKeys: Settings.secretKeys,
      enabled: enabled
    )
    guard !problems.isEmpty else { return manifests }

    var refused: Set<ServiceIdentifier> = []
    for problem in problems {
      if problem.isFatal {
        logger.error(
          "A service manifest is invalid",
          metadata: [
            "problem": .string(String(describing: problem))
          ])
        refused.formUnion(Self.services(in: problem))
      } else {
        logger.warning(
          "A service configuration needs attention",
          metadata: [
            "problem": .string(String(describing: problem))
          ])
        await alerts?.raise(
          UserAlert(
            severity: .warning,
            title: "Two connection methods are enabled",
            body: String(describing: problem),
            source: "Integrations",
            actions: [.openSettings(section: "settings")],
            dedupeKey: "manifest.exclusive-conflict"
          )
        )
      }
    }

    guard !refused.isEmpty else { return manifests }
    return manifests.filter { !refused.contains($0.id) }
  }

  /// Which services a problem implicates, so only those are refused.
  private static func services(in problem: ManifestProblem) -> [ServiceIdentifier] {
    switch problem {
    case .malformedIdentifier(let id), .duplicateIdentifier(let id), .dependsOnItself(let id):
      [id]
    case .unknownDependency(let service, _),
      .entitlementRequestsSecret(let service, _),
      .entitlementReservedForBuiltIns(let service, _),
      .duplicateFieldKey(let service, _),
      .conditionReferencesUnknownField(let service, _),
      .emptySelect(let service, _),
      .hostTooOld(let service, _, _),
      .migrationBeyondVersion(let service, _, _),
      .duplicateMigration(let service, _),
      .malformedToolIdentifier(let service, _),
      .duplicateTool(let service, _),
      .toolWithoutBuilds(let service, _),
      .duplicateToolBuild(let service, _, _),
      .toolWithoutSpawnProcess(let service, _),
      .toolHostNotDeclared(let service, _, _),
      .unverifiableTool(let service, _),
      .recommendedVersionNotAddressable(let service, _):
      [service]
    // Every service in the cycle is unstartable, not just the one named first.
    case .dependencyCycle(let path):
      path
    case .exclusiveCategoryConflict:
      []
    }
  }

  /// Migrates and seeds every manifest's settings.
  static func prepare(
    manifests: [ServiceManifest],
    store: SettingsStore,
    logger: Logger
  ) async {
    let storage = SettingsStorageAdapter(store: store)

    for manifest in manifests {
      let result = await ServiceMigrator.migrate(manifest, in: storage)

      // Logged only when something actually moved. A first run and an unchanged version
      // are the common cases and saying so every launch would bury the one line that
      // matters.
      if !result.applied.isEmpty {
        logger.info(
          "Migrated a service's settings",
          metadata: [
            "service": .string(manifest.id.rawValue),
            "from": .string(result.from ?? "none"),
            "to": .string(result.to),
            "steps": .string(result.applied.joined(separator: ", ")),
          ])
      }

      await seedDefaults(manifest, store: store)
    }
  }

  /// Writes a declared default for any field that has never been set.
  ///
  /// Only where a default is meaningful: a `select`'s first option, and a `toggle` declared
  /// on. A text field's "default" is the empty string, and writing that would turn "never
  /// configured" into "configured as empty", which the required-field check below would
  /// then fail to catch.
  ///
  /// An off-by-default toggle is not seeded either, because an unset flag already reads as
  /// `false` — writing it would only turn "never chosen" into "chosen", and a later change
  /// to that default would then be ignored on every existing install.
  static func seedDefaults(_ manifest: ServiceManifest, store: SettingsStore) async {
    for field in manifest.fields {
      let value: String
      switch field.kind {
      case .select(let options):
        guard let first = options.first else { continue }
        value = first.value
      case .toggle(let isOnByDefault):
        guard isOnByDefault else { continue }
        value = "true"
      default:
        continue
      }
      let key = manifest.storageKey(for: field.key)
      // Only when never set. Someone who has explicitly turned an on-by-default toggle
      // off has chosen that, and a seed must not undo it on the next launch.
      guard await store.string(forKey: key) == nil else { continue }
      try? await store.set(value, forKey: key, isSecret: field.isSecret)
    }
  }

  /// Clears everything a service has stored and puts its declared defaults back.
  ///
  /// Scoped to the service's own namespace, so "reset zrok" cannot touch ngrok's
  /// configuration or the core settings — the same prefix rule that governs reads. Which is
  /// also why this is safe to offer per service at all: without namespaces, "reset" would
  /// have to mean "reset everything".
  ///
  /// The migration stamp is DELIBERATELY kept. It is bookkeeping, not configuration —
  /// clearing it would make the next launch treat an established install as a first run,
  /// and any migration that has already reshaped data would be skipped rather than re-run.
  ///
  /// - Returns: How many stored values were cleared, so the caller can say "nothing to
  ///   reset" rather than claiming to have done something.
  @discardableResult
  public static func resetToDefaults(
    _ manifest: ServiceManifest,
    store: SettingsStore
  ) async -> Int {
    var cleared = 0
    for field in manifest.fields {
      let key = manifest.storageKey(for: field.key)
      guard let existing = await store.string(forKey: key), !existing.isEmpty else { continue }
      // Removed, not blanked. A row holding "" is still a row, and `seedDefaults`
      // below would then decline to fill it because something is already there — so a
      // reset would clear the value and fail to restore the default in one go.
      try? await store.remove(forKey: key)
      cleared += 1
    }

    // Put back the values the manifest says a fresh install should have.
    await seedDefaults(manifest, store: store)
    return cleared
  }

  /// Required fields a service has no value for.
  ///
  /// Reported rather than enforced here: whether a missing field should stop the service is
  /// the service's decision, and it is the one that can explain what the field is for.
  ///
  /// `visibleWhen` is honoured, and it has to be: a field the form is not SHOWING cannot be
  /// one the user has failed to fill in. Without this, the first conditional-and-required
  /// field anyone declares turns into a permanent complaint on the connection row — "needs:
  /// Tunnel Token" for every user who picked the mode that has no token — pointing at a
  /// control that is not on screen. The rule matches `ServiceFormView.isVisible`, which is
  /// what decides whether the user was ever asked.
  public static func missingRequiredFields(
    _ manifest: ServiceManifest,
    store: SettingsStore
  ) async -> [FieldDescriptor] {
    var missing: [FieldDescriptor] = []
    for field in manifest.fields where field.isRequired {
      if let condition = field.visibleWhen {
        let sibling = await store.string(
          forKey: manifest.storageKey(for: condition.field)
        )
        guard condition.isSatisfied(by: sibling ?? "") else { continue }
      }
      let value = await store.string(forKey: manifest.storageKey(for: field.key))
      if value?.isEmpty ?? true { missing.append(field) }
    }
    return missing
  }
}
