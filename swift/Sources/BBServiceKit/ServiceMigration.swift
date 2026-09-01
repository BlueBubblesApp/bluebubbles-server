//  ServiceMigration
//  Moving a service's stored configuration from one version of its manifest to the next.
//
//  A service that ships a new version and renames one of its fields has, without this, thrown
//  away whatever the user had configured: the old key still sits in the database and the new
//  one reads as unset, so the service reports itself unconfigured and the value the user typed
//  is still there, invisible. That is the same silent failure as a credential migrated to the
//  wrong place, and it happens on the ordinary path — an update — rather than a rare one.
//
//  **Migrations are DATA, like the rest of the manifest.** No closures, no code hook, and that
//  is a deliberate limit rather than an oversight: a third-party manifest arrives as JSON, and
//  an operation a plugin cannot express is one that only first-party services could ever use.
//  Renames, removals, copies and defaults cover what a settings change actually needs. Anything
//  requiring real computation belongs in the service's own `start`, where it can report a
//  reason and be tested — not in a migration that runs once, silently, on someone else's Mac.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import Foundation

/// One step, taking a service's stored settings up to `toVersion`.
public struct FieldMigration: Sendable, Codable, Equatable {

  public enum Operation: Sendable, Codable, Equatable {
    /// Move a value to a new field name, keeping it.
    case rename(from: String, to: String)
    /// Drop a field the service no longer has.
    case remove(field: String)
    /// Duplicate a value into a second field, keeping the original — for a field that
    /// splits in two.
    case copy(from: String, to: String)
    /// Give a NEW field a starting value, and only when it has none.
    ///
    /// Never overwrites: a user who already set it wins over a migration's idea of a
    /// sensible default, which is the difference between filling a gap and undoing a
    /// decision.
    case setDefault(field: String, value: String)
  }

  /// The manifest version this step brings the stored settings up to.
  public let toVersion: String
  public let operations: [Operation]
  /// Shown in the log when it runs, so an upgrade that moved a user's data says so.
  public let summary: String

  public init(toVersion: String, summary: String = "", operations: [Operation]) {
    self.toVersion = toVersion
    self.summary = summary
    self.operations = operations
  }
}

/// The storage a migration reads and writes, in the only terms it needs.
///
/// A protocol rather than the settings store itself, so this module keeps no dependency on the
/// settings layer — and so a test can run a migration against a dictionary and check the
/// result, which is most of what makes migrations reviewable at all.
public protocol MigratableStorage: Sendable {
  func value(forKey key: String) async -> String?
  func setValue(_ value: String?, forKey key: String, isSecret: Bool) async
}

public struct ServiceMigrationResult: Sendable, Equatable {
  public let from: String?
  public let to: String
  public let applied: [String]
  /// True when nothing ran because this is a first install rather than an upgrade.
  public let wasFirstRun: Bool
}

public enum ServiceMigrator {

  /// The key a service's applied version is recorded under, inside its own namespace.
  ///
  /// Double-underscored so it cannot collide with a declared field — `__version` is not a
  /// legal-looking field name, and the validator would reject a manifest declaring one.
  public static func versionKey(for manifest: ServiceManifest) -> String {
    "\(manifest.id.settingsNamespace)__version"
  }

  /// Brings a service's stored settings up to its manifest version.
  ///
  /// Returns what it did, so the caller can log it. Applying nothing is the common case and
  /// is not an error.
  @discardableResult
  public static func migrate(
    _ manifest: ServiceManifest,
    in storage: any MigratableStorage
  ) async -> ServiceMigrationResult {
    let versionKey = versionKey(for: manifest)
    let stored = await storage.value(forKey: versionKey)

    // A first install has nothing to migrate. Stamping the current version WITHOUT running
    // anything matters: a migration like `setDefault` would otherwise write values for
    // fields the user is about to configure, and a `rename` would look for keys that were
    // never written.
    guard let stored else {
      await storage.setValue(manifest.version, forKey: versionKey, isSecret: false)
      return ServiceMigrationResult(
        from: nil, to: manifest.version, applied: [], wasFirstRun: true
      )
    }

    // A downgrade — the stored data is newer than the code reading it. Migrations only run
    // forwards, so the honest thing is to leave everything alone rather than guess: a
    // "reverse migration" would be inventing a shape the older version never wrote.
    guard compare(stored, manifest.version) != .orderedDescending else {
      return ServiceMigrationResult(
        from: stored, to: stored, applied: [], wasFirstRun: false
      )
    }

    let pending = manifest.migrations
      .filter { compare($0.toVersion, stored) == .orderedDescending }
      .sorted { compare($0.toVersion, $1.toVersion) == .orderedAscending }

    var applied: [String] = []
    for migration in pending {
      for operation in migration.operations {
        await apply(operation, manifest: manifest, storage: storage)
      }
      applied.append(migration.toVersion)
    }

    await storage.setValue(manifest.version, forKey: versionKey, isSecret: false)
    return ServiceMigrationResult(
      from: stored, to: manifest.version, applied: applied, wasFirstRun: false
    )
  }

  private static func apply(
    _ operation: FieldMigration.Operation,
    manifest: ServiceManifest,
    storage: any MigratableStorage
  ) async {
    // Every key is assembled from the manifest's namespace, so a migration cannot reach
    // outside its own service even by naming a fully-qualified key — the same rule that
    // governs field declarations.
    func key(_ field: String) -> String { manifest.storageKey(for: field) }

    // Whether the destination holds a credential, taken from the field the service
    // declares. A renamed secret that lands in the database instead of the Keychain would
    // be a downgrade in storage nobody asked for.
    func isSecret(_ field: String) -> Bool {
      manifest.fields.first { $0.key == field }?.isSecret ?? false
    }

    switch operation {
    case .rename(let from, let to):
      guard let value = await storage.value(forKey: key(from)) else { return }
      await storage.setValue(value, forKey: key(to), isSecret: isSecret(to))
      await storage.setValue(nil, forKey: key(from), isSecret: isSecret(from))

    case .copy(let from, let to):
      guard let value = await storage.value(forKey: key(from)) else { return }
      await storage.setValue(value, forKey: key(to), isSecret: isSecret(to))

    case .remove(let field):
      await storage.setValue(nil, forKey: key(field), isSecret: isSecret(field))

    case .setDefault(let field, let value):
      // Only when absent. See the note on the case itself.
      guard await storage.value(forKey: key(field)) == nil else { return }
      await storage.setValue(value, forKey: key(field), isSecret: isSecret(field))
    }
  }

  /// Compares dotted numeric versions: `1.10.0` is newer than `1.9.0`.
  ///
  /// Not full semantic versioning — no pre-release tags, no build metadata. Those exist to
  /// order releases for humans, and this only has to decide which migrations have already
  /// run. A component that is not a number sorts as 0 rather than throwing, because a
  /// malformed version in a third-party manifest must not stop the service from loading.
  public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let right = rhs.split(separator: ".").map { Int($0) ?? 0 }

    for index in 0..<max(left.count, right.count) {
      let a = index < left.count ? left[index] : 0
      let b = index < right.count ? right[index] : 0
      if a != b { return a < b ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
  }
}
