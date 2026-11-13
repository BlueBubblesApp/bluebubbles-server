//  LiveRestoreTargetTests
//  An import into a running server is seen by that server at once, and cannot be undone
//  by it.
//
//  A running server keeps a cache of contact lookups and holds both access-control lists in
//  memory, rewriting each list's table from memory on its next change. Written beneath it,
//  a restored blocklist was overwritten by the next block anywhere; and a reload after the
//  write could not fix that, because a block landing between the write and the reload was
//  written from the old lists and read back as the new ones. The restore is written through
//  the controller now, and these tests put a block exactly where it used to win.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAppStore
import BBAuth
import BBBuiltIns
import BBContacts
import BBExport
import BBPersistence
import BBSettings
import BBTestSupport
import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

/// The real store, with one block landing at the moment that matters, once.
///
/// The hook runs inside `saveBlocked`, which is the write lane's own pass, so it is the
/// block that arrives while the restored lists are being written; and inside
/// `loadAccessControl`, which is where a reload after a write beneath the controller would
/// read the table back. Either way it runs once.
private final class InterleavingPersistence: AccessControlPersistence, @unchecked Sendable {
  private let inner: AccessControlStore
  private let lock = NSLock()
  private var hook: (@Sendable () async -> Void)?
  private var refusesBlockedWrites = false

  struct Refused: Error {}

  init(inner: AccessControlStore) { self.inner = inner }

  func arm(_ hook: @escaping @Sendable () async -> Void) {
    lock.withLock { self.hook = hook }
  }

  func refuseBlockedWrites() {
    lock.withLock { refusesBlockedWrites = true }
  }

  private func takeHook() -> (@Sendable () async -> Void)? {
    lock.withLock {
      defer { hook = nil }
      return hook
    }
  }

  func loadAccessControl() async throws -> (
    blocked: [BlockedClient], allowlist: [AllowedClient]
  ) {
    if let hook = takeHook() { await hook() }
    return try await inner.loadAccessControl()
  }

  func saveBlocked(_ blocked: [BlockedClient]) async throws {
    if let hook = takeHook() { await hook() }
    if lock.withLock({ refusesBlockedWrites }) { throw Refused() }
    try await inner.saveBlocked(blocked)
  }

  func saveAllowlist(_ allowlist: [AllowedClient]) async throws {
    try await inner.saveAllowlist(allowlist)
  }

  func loadFailures(limit: Int) async throws -> [AuthFailureRecord] {
    try await inner.loadFailures(limit: limit)
  }

  func saveFailures(_ failures: [AuthFailureRecord]) async throws {
    try await inner.saveFailures(failures)
  }
}

/// Records what the client-backup table held at each announcement, which says whether a
/// section was announced before the next one was written.
private actor RecordingTarget: RestoreTarget {
  private let database: AppDatabase
  private(set) var backupsAtAnnouncement: [ExportSection: Int] = [:]

  init(database: AppDatabase) { self.database = database }

  func runningAccessControl() -> AccessControlService? { nil }

  func sectionWasRestored(_ section: ExportSection) async {
    // A read that fails records -1, which no expectation accepts.
    backupsAtAnnouncement[section] =
      (try? await database.read { db in try Backup.fetchCount(db) }) ?? -1
  }
}

@Suite("An import reaches a running server", .serialized)
struct LiveRestoreTargetTests {

  private let logger = Logger(label: "bluebubbles.test.restore")
  private static let address = "+12025550143"

  private func harness() async throws -> (AppDatabase, SettingsStore) {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    return (database, try await TestSettings.store(database: database))
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-restore-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// An archive whose blocklist is one permanent block of `192.0.2.20`.
  private func accessControlArchive(in root: URL) async throws -> URL {
    let (source, sourceSettings) = try await harness()
    let sourceAccess = AccessControlService(persistence: AccessControlStore(database: source))
    await sourceAccess.blockPermanently(address: "192.0.2.20", reason: "in the archive")
    await sourceAccess.flushPersistedState()
    return try await ServerExporter(
      database: source, settings: sourceSettings, services: BuiltInManifests.all,
      serverVersion: "test", logger: logger
    ).export(sections: [.accessControl], to: root).url
  }

  @Test("Contact lookups and access control follow a restore, and the next block keeps it")
  func restoreReachesLiveState() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // The archive: one contact and one block.
    let (source, sourceSettings) = try await harness()
    try await ContactIndex(database: source).upsert([
      ContactRecord(
        id: "1", source: .local, firstName: "Restored", phoneNumbers: [Self.address])
    ])
    let sourceAccess = AccessControlService(persistence: AccessControlStore(database: source))
    await sourceAccess.blockPermanently(address: "192.0.2.20", reason: "in the archive")
    await sourceAccess.flushPersistedState()
    let report = try await ServerExporter(
      database: source, settings: sourceSettings, services: BuiltInManifests.all,
      serverVersion: "test", logger: logger
    ).export(sections: [.contacts, .accessControl], to: root)

    // A running server with its own of each, the lookup already cached.
    let (target, targetSettings) = try await harness()
    let contacts = ContactIndex(database: target)
    try await contacts.upsert([
      ContactRecord(
        id: "1", source: .local, firstName: "Replaced", phoneNumbers: [Self.address])
    ])
    #expect(try await contacts.findContact(address: Self.address)?.firstName == "Replaced")
    let access = AccessControlService(persistence: AccessControlStore(database: target))
    await access.blockPermanently(address: "192.0.2.10", reason: "replaced by the archive")
    await access.flushPersistedState()

    let live = LiveRestoreTarget()
    await live.attach(contacts: contacts, accessControl: access)
    let importer = ServerImporter(
      database: target, settings: targetSettings, services: BuiltInManifests.all,
      target: live, logger: logger)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    _ = try await importer.apply(inspection, sections: [.contacts, .accessControl])

    #expect(try await contacts.findContact(address: Self.address)?.firstName == "Restored")
    #expect(await access.blockedClients().map(\.address) == ["192.0.2.20"])

    // The next change rewrites the table from memory, which must now be the restored list.
    await access.blockPermanently(address: "192.0.2.30", reason: "after the restore")
    await access.flushPersistedState()
    let stored = try await AccessControlStore(database: target).loadAccessControl()
    #expect(Set(stored.blocked.map(\.address)) == ["192.0.2.20", "192.0.2.30"])
  }

  /// The failure this replaced, made deterministic. Written beneath the controller and
  /// then reloaded, the block below landed between the two: the controller wrote it
  /// beside the OLD list (`192.0.2.10`), the reload read that back, and the restored
  /// `192.0.2.20` was gone from memory and from the table, with nothing reported. Written
  /// through the controller, the block arrives while the restored lists are being written,
  /// and joins them.
  @Test("A block that lands while the restore is being written joins the restored lists")
  func blockDuringTheRestoreKeepsBoth() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try await accessControlArchive(in: root)

    let (target, targetSettings) = try await harness()
    let persistence = InterleavingPersistence(inner: AccessControlStore(database: target))
    let access = AccessControlService(persistence: persistence)
    await access.blockPermanently(address: "192.0.2.10", reason: "replaced by the archive")
    await access.flushPersistedState()

    // Armed only now, so the setup's own writes do not spend it.
    persistence.arm {
      await access.blockPermanently(address: "192.0.2.30", reason: "during the restore")
    }
    let live = LiveRestoreTarget()
    await live.attach(contacts: ContactIndex(database: target), accessControl: access)
    let importer = ServerImporter(
      database: target, settings: targetSettings, services: BuiltInManifests.all,
      target: live, logger: logger)
    let inspection = try await importer.inspect(archive)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    _ = try await importer.apply(inspection, sections: [.accessControl])
    await access.flushPersistedState()

    let expected: Set<String> = ["192.0.2.20", "192.0.2.30"]
    #expect(Set(await access.blockedClients().map(\.address)) == expected)
    let stored = try await AccessControlStore(database: target).loadAccessControl()
    #expect(Set(stored.blocked.map(\.address)) == expected)
  }

  /// The lists are in force either way; what the person is owed is being told they did
  /// not reach the disk, rather than an import that reports success over a table still
  /// holding the old ones.
  @Test("A restore whose lists cannot be written says so, and keeps them in force")
  func failedWriteIsReported() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try await accessControlArchive(in: root)

    let (target, targetSettings) = try await harness()
    let persistence = InterleavingPersistence(inner: AccessControlStore(database: target))
    let access = AccessControlService(persistence: persistence)
    persistence.refuseBlockedWrites()

    let live = LiveRestoreTarget()
    await live.attach(contacts: ContactIndex(database: target), accessControl: access)
    let importer = ServerImporter(
      database: target, settings: targetSettings, services: BuiltInManifests.all,
      target: live, logger: logger)
    let inspection = try await importer.inspect(archive)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    await #expect(throws: InterleavingPersistence.Refused.self) {
      _ = try await importer.apply(inspection, sections: [.accessControl])
    }
    #expect(await access.blockedClients().map(\.address) == ["192.0.2.20"])
  }

  /// Announced once the whole import had finished, a server answered from its old copies
  /// for as long as the later sections took, and the sealed one decrypts and writes to the
  /// Keychain. Contacts are written before client backups, so the backups table being
  /// empty when contacts are announced is the announcement arriving in between.
  @Test("Each section is announced as soon as it is written")
  func eachSectionIsAnnouncedAtOnce() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, sourceSettings) = try await harness()
    try await ContactIndex(database: source).upsert([
      ContactRecord(
        id: "1", source: .local, firstName: "Restored", phoneNumbers: [Self.address])
    ])
    try await BackupRepository(database: source).save(
      kind: "theme", name: "Dark", payload: Data("{}".utf8))
    let report = try await ServerExporter(
      database: source, settings: sourceSettings, services: BuiltInManifests.all,
      serverVersion: "test", logger: logger
    ).export(sections: [.contacts, .clientBackups], to: root)

    let (target, targetSettings) = try await harness()
    let recording = RecordingTarget(database: target)
    let importer = ServerImporter(
      database: target, settings: targetSettings, services: BuiltInManifests.all,
      target: recording, logger: logger)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    _ = try await importer.apply(inspection, sections: [.contacts, .clientBackups])

    #expect(await recording.backupsAtAnnouncement == [.contacts: 0, .clientBackups: 1])
  }

  /// The target is only as good as the two hand-overs: the importer a front end builds has
  /// to be given it, and the server built over the same storage has to attach to it. Either
  /// one missing is silence rather than an error: the import writes beneath the controller.
  @Test("The front ends' importer reaches the server, and the composition attaches it")
  func targetIsWired() throws {
    let operations = try SourceScanner.file(
      "Sources/BlueBubblesServerCore/Composition/StorageOperations.swift"
    ).text
    #expect(operations.contains("target: restoreTarget"))
    let composition = try SourceScanner.family(
      "Sources/BlueBubblesServerCore/Composition/ServerComposition.swift"
    ).text
    #expect(
      composition.contains(
        "await storage.restoreTarget.attach(contacts: contacts, accessControl: accessControl)"))
    // Restored Firebase credentials restart push, which needs the lifecycle attached too.
    #expect(composition.contains("await storage.restoreTarget.attach(lifecycle: lifecycle)"))
    let target = try SourceScanner.file(
      "Sources/BlueBubblesServerCore/Composition/LiveRestoreTarget.swift"
    ).text
    #expect(target.contains("case .firebaseCredentials:\n      await lifecycle?.restartPush()"))
  }
}
