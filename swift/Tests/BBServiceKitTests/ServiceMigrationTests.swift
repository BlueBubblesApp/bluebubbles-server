//  ServiceMigrationTests
//  Bringing a service's stored settings forward when its version moves.
//
//  The failure this prevents is quiet and happens on the most ordinary path there is — an
//  update. A service renames a field, ships, and the value the user configured is still in the
//  database under the old key while the service reads the new one and reports itself
//  unconfigured. Nothing errors; the setting simply appears to have been forgotten.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import Foundation
import Testing

@testable import BBServiceKit

@Suite("Service migrations")
struct ServiceMigrationTests {

  /// A dictionary standing in for the settings store, which is all a migration needs.
  private actor Storage: MigratableStorage {
    private var values: [String: String]
    private(set) var secretKeys: Set<String> = []

    init(_ values: [String: String] = [:]) { self.values = values }

    func value(forKey key: String) async -> String? { values[key] }

    func setValue(_ value: String?, forKey key: String, isSecret: Bool) async {
      if let value {
        values[key] = value
        if isSecret { secretKeys.insert(key) }
      } else {
        values.removeValue(forKey: key)
      }
    }

    func snapshot() -> [String: String] { values }
  }

  private static let id = ServiceIdentifier("app.example.thing")

  private func manifest(
    version: String,
    fields: [FieldDescriptor] = [],
    migrations: [FieldMigration] = []
  ) -> ServiceManifest {
    ServiceManifest(
      id: Self.id,
      name: "Thing",
      summary: "A thing.",
      category: .integration,
      version: version,
      settings: fields.map { .field($0) },
      migrations: migrations,
      isBuiltIn: false
    )
  }

  private func key(_ field: String) -> String { "\(Self.id.settingsNamespace)\(field)" }

  // MARK: - First run

  @Test("A first install runs nothing and stamps the current version")
  func firstRunIsStamped() async {
    // Running migrations on a fresh install would be actively wrong, not merely wasteful:
    // `setDefault` would write values for fields the user is about to fill in, and a
    // `rename` would hunt for keys that were never written.
    let storage = Storage()
    let manifest = manifest(
      version: "2.0.0",
      migrations: [
        FieldMigration(
          toVersion: "2.0.0",
          operations: [.setDefault(field: "region", value: "us")]
        )
      ]
    )

    let result = await ServiceMigrator.migrate(manifest, in: storage)

    #expect(result.wasFirstRun)
    #expect(result.applied.isEmpty)
    #expect(await storage.value(forKey: ServiceMigrator.versionKey(for: manifest)) == "2.0.0")
    #expect(await storage.value(forKey: key("region")) == nil, "nothing should have been written")
  }

  // MARK: - Upgrades

  @Test("A rename moves the value and clears the old key")
  func renameMovesTheValue() async {
    // The case that motivates the whole file. Leaving the old key behind would also mean a
    // later downgrade silently resurrecting a stale value.
    let storage = Storage([
      ServiceMigrator.versionKey(for: manifest(version: "1.0.0")): "1.0.0",
      "app.example.thing.token": "abc123",
    ])
    let manifest = manifest(
      version: "2.0.0",
      fields: [FieldDescriptor(key: "auth_token", label: "Token", kind: .text())],
      migrations: [
        FieldMigration(
          toVersion: "2.0.0",
          operations: [.rename(from: "token", to: "auth_token")]
        )
      ]
    )

    let result = await ServiceMigrator.migrate(manifest, in: storage)

    #expect(result.applied == ["2.0.0"])
    #expect(await storage.value(forKey: key("auth_token")) == "abc123")
    #expect(await storage.value(forKey: key("token")) == nil)
  }

  @Test("A renamed secret stays a secret")
  func renamedSecretsKeepTheirStorage() async {
    // Taken from the destination FIELD, not from the operation. A credential that moved
    // into the database instead of the Keychain would be a storage downgrade nobody asked
    // for and nothing would report.
    let storage = Storage([
      ServiceMigrator.versionKey(for: manifest(version: "1.0.0")): "1.0.0",
      "app.example.thing.token": "secret-value",
    ])
    let manifest = manifest(
      version: "2.0.0",
      fields: [
        FieldDescriptor(
          key: "auth_token", label: "Token", kind: .text(), isSecret: true
        )
      ],
      migrations: [
        FieldMigration(
          toVersion: "2.0.0",
          operations: [.rename(from: "token", to: "auth_token")]
        )
      ]
    )

    await ServiceMigrator.migrate(manifest, in: storage)
    #expect(await storage.secretKeys.contains(key("auth_token")))
  }

  @Test("Steps run in order, and only the ones not yet applied")
  func onlyPendingStepsRun() async {
    // An install two versions behind has to walk through both; one already at 2.0.0 must
    // not re-run 2.0.0, or a rename would move a value that is already where it belongs.
    let storage = Storage([
      "app.example.thing.__version": "1.0.0",
      "app.example.thing.a": "value",
    ])
    let manifest = manifest(
      version: "3.0.0",
      fields: [FieldDescriptor(key: "c", label: "C", kind: .text())],
      migrations: [
        // Declared out of order deliberately: the migrator sorts them.
        FieldMigration(toVersion: "3.0.0", operations: [.rename(from: "b", to: "c")]),
        FieldMigration(toVersion: "2.0.0", operations: [.rename(from: "a", to: "b")]),
      ]
    )

    let result = await ServiceMigrator.migrate(manifest, in: storage)

    #expect(result.applied == ["2.0.0", "3.0.0"])
    #expect(
      await storage.value(forKey: key("c")) == "value", "the value should have walked a -> b -> c")
    #expect(await storage.value(forKey: key("a")) == nil)
  }

  @Test("Migrating twice does nothing the second time")
  func migrationsAreIdempotent() async {
    let storage = Storage([
      "app.example.thing.__version": "1.0.0",
      "app.example.thing.token": "abc",
    ])
    let manifest = manifest(
      version: "2.0.0",
      fields: [FieldDescriptor(key: "auth_token", label: "T", kind: .text())],
      migrations: [
        FieldMigration(
          toVersion: "2.0.0", operations: [.rename(from: "token", to: "auth_token")]
        )
      ]
    )

    await ServiceMigrator.migrate(manifest, in: storage)
    let second = await ServiceMigrator.migrate(manifest, in: storage)

    #expect(second.applied.isEmpty)
    #expect(await storage.value(forKey: key("auth_token")) == "abc")
  }

  // MARK: - The careful cases

  @Test("setDefault fills a gap but never overrides a choice")
  func defaultsDoNotOverride() async {
    // A user who set the value wins over a migration's idea of a sensible one. The
    // opposite would silently revert a deliberate decision on update, which is the worst
    // thing an automatic migration can do.
    let storage = Storage([
      "app.example.thing.__version": "1.0.0",
      "app.example.thing.region": "eu",
    ])
    let manifest = manifest(
      version: "2.0.0",
      fields: [
        FieldDescriptor(key: "region", label: "Region", kind: .text()),
        FieldDescriptor(key: "mode", label: "Mode", kind: .text()),
      ],
      migrations: [
        FieldMigration(
          toVersion: "2.0.0",
          operations: [
            .setDefault(field: "region", value: "us"),
            .setDefault(field: "mode", value: "proxy"),
          ]
        )
      ]
    )

    await ServiceMigrator.migrate(manifest, in: storage)

    #expect(await storage.value(forKey: key("region")) == "eu", "an existing choice must win")
    #expect(await storage.value(forKey: key("mode")) == "proxy", "an absent value gets the default")
  }

  @Test("A downgrade changes nothing")
  func downgradeIsLeftAlone() async {
    // Stored data newer than the code reading it. Migrations only run forwards, so the
    // honest move is to touch nothing — a "reverse migration" would be inventing a shape
    // the older version never wrote.
    let storage = Storage([
      "app.example.thing.__version": "3.0.0",
      "app.example.thing.value": "keep me",
    ])
    let manifest = manifest(
      version: "2.0.0",
      migrations: [
        FieldMigration(
          toVersion: "2.0.0", operations: [.remove(field: "value")]
        )
      ]
    )

    let result = await ServiceMigrator.migrate(manifest, in: storage)

    #expect(result.applied.isEmpty)
    #expect(await storage.value(forKey: key("value")) == "keep me")
    #expect(await storage.value(forKey: "app.example.thing.__version") == "3.0.0")
  }

  @Test("A migration cannot reach outside its own service")
  func migrationsAreNamespaced() async {
    // Keys are assembled from the manifest's namespace, so naming a fully-qualified key
    // does not escape it — the same rule that governs field declarations.
    let storage = Storage([
      "app.example.thing.__version": "1.0.0",
      "password": "do not touch",
    ])
    let manifest = manifest(
      version: "2.0.0",
      migrations: [
        FieldMigration(
          toVersion: "2.0.0", operations: [.remove(field: "password")]
        )
      ]
    )

    await ServiceMigrator.migrate(manifest, in: storage)
    #expect(await storage.value(forKey: "password") == "do not touch")
  }

  // MARK: - Versions

  @Test("Versions compare numerically, not as strings")
  func versionOrdering() {
    // `1.10.0` is newer than `1.9.0`, which string comparison gets backwards — and getting
    // it backwards means skipping a migration or re-running one.
    #expect(ServiceMigrator.compare("1.10.0", "1.9.0") == .orderedDescending)
    #expect(ServiceMigrator.compare("1.0.0", "1.0") == .orderedSame)
    #expect(ServiceMigrator.compare("2.0.0", "10.0.0") == .orderedAscending)
    // A malformed component sorts as zero rather than throwing: a bad version in a
    // third-party manifest must not stop the service from loading.
    #expect(ServiceMigrator.compare("1.x.0", "1.0.0") == .orderedSame)
  }

  @Test("A migration newer than its own manifest is refused")
  func migrationBeyondVersionIsInvalid() {
    // It could never run — the migrator stamps the manifest version when it finishes — so
    // it is dead code that looks live.
    let problems = ManifestValidator.validate(
      manifest(
        version: "1.0.0",
        migrations: [FieldMigration(toVersion: "2.0.0", operations: [])]
      ),
      secretKeys: []
    )
    #expect(
      problems.contains {
        if case .migrationBeyondVersion = $0 { return true } else { return false }
      })
  }

  @Test("Two migrations to the same version are refused")
  func duplicateMigrationsAreInvalid() {
    let problems = ManifestValidator.validate(
      manifest(
        version: "2.0.0",
        migrations: [
          FieldMigration(toVersion: "2.0.0", operations: []),
          FieldMigration(toVersion: "2.0.0", operations: []),
        ]
      ),
      secretKeys: []
    )
    #expect(
      problems.contains { if case .duplicateMigration = $0 { return true } else { return false } })
  }
}
