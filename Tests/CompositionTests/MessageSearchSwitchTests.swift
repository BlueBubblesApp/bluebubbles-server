//  MessageSearchSwitchTests
//  "Turning it off deletes it", asked of the real service under the real registry.
//
//  The promise is made to a person, and a person does not know which state the service is in:
//  refused at its Full Disk Access gate, given up on, part-way through a retry, or running. So
//  every test here drives the registry the way the settings pump does, and none of them calls
//  the service directly. A test that started the service by hand walked straight past the gate
//  that kept the deletion from running, which is how that bug passed every test in the suite.
//
//  **Every store here is a temporary one, through `SearchHost`.** `AppContextFixture` builds its
//  context around `SearchIndexStore()`, whose default URL is the real `search-index.db` of
//  whoever is running the suite, and these tests delete what they are handed.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBBuiltIns
import BBCore
import BBIMessage
import BBInterfaces
import BBPersistence
import BBSerialization
import BBSettings
import BBSystem
import BBTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import BBServiceKit
@testable import BlueBubblesServerCore

/// The real container, with the index somewhere else and the read path able to arrive late.
private struct SearchHost: ScopedSettingsProviding, LoggerProviding, MessageSourceProviding,
  MessageReindexerPublishing, SearchIndexProviding, HealthChangeReporting
{
  let inner: AppContext
  let store: SearchIndexStore
  let readPath: Locked<MessageRepository?>

  func scopedSettings(for manifest: ServiceManifest) -> ScopedSettings {
    inner.scopedSettings(for: manifest)
  }
  var logger: Logger { inner.logger }
  var messages: MessageRepository? { readPath.withLock { $0 } }
  var serializer: MessageSerializer? { inner.serializer }
  var searchIndex: SearchIndexStore { store }
  func publish(messageReindexer reindexer: any MessageReindexing) async {
    await inner.publish(messageReindexer: reindexer)
  }
  func withdrawMessageReindexer() async { await inner.withdrawMessageReindexer() }
  func serviceHealthDidChange(_ id: ServiceIdentifier) async {}
}

/// What the manifest depends on. Nothing here is about the monitor.
private actor PermissionsStandIn: Service {
  static let manifest = BuiltInManifests.permissions
  init(host: SearchHost) {}
  func start() async throws {}
  func stop() async {}
  var health: ServiceHealth { get async { .running } }
}

@Suite("Turning Message Search off", .serialized)
struct MessageSearchSwitchTests {

  private struct Harness {
    let root: URL
    let store: SearchIndexStore
    let settings: SettingsStore
    let host: SearchHost
    let repository: MessageRepository
    let granted: Locked<Bool>
    let registry: ServiceRegistry<SearchHost>

    /// What the settings pump does for a write: the store emits, the registry routes.
    func setSwitch(_ on: Bool) async throws {
      try await settings.set(Settings.searchIndexEnabled, to: on)
      await registry.apply(SettingsChange(changedKeys: [Settings.searchIndexEnabled.key]))
    }

    var health: ServiceHealth? {
      get async { await registry.health()[MessageSearchIndexService.id] }
    }

    /// Leaves an index on disk, holding a word the fixture does not contain, so a rebuild from
    /// nothing can be told from a resumption: only the first loses it.
    func plantIndex(word: String = "zzqqxplantedword") async throws {
      try await store.open()
      let queue = try await store.connection()
      try await queue.write { db in
        try db.execute(
          sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
          arguments: [9_000_000, word])
      }
      try await store.setBackfillCursor(9_000_000)
      try await store.setBackfillComplete(true)
      try await store.close()
    }

    func matches(_ word: String) async throws -> [Int64] {
      let queue = try await store.connection()
      return try await queue.read { db in
        try Int64.fetchAll(
          db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ?",
          arguments: [word])
      }
    }
  }

  private func harness(enabled: Bool, granted: Bool) async throws -> Harness {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-switch-\(UUID().uuidString)", isDirectory: true)
    let chatPath = try CommittedChatDB.copy(into: root)
    let context = try await AppContextFixture.make(
      chatDatabase: try ReadOnlyDatabase(path: chatPath.path))
    let repository = try #require(context.messages)
    try await context.settings.set(Settings.searchIndexEnabled, to: enabled)

    let store = SearchIndexStore(url: root.appendingPathComponent("index.db"))
    let host = SearchHost(inner: context, store: store, readPath: Locked(repository))
    let isGranted = Locked(granted)
    let registry = ServiceRegistry<SearchHost>(
      host: host,
      permissionCheck: { _ in isGranted.withLock { $0 } },
      permissionTitle: { PermissionsService.title(for: $0) }
    )
    await registry.register(PermissionsStandIn.self)
    await registry.register(MessageSearchIndexService.self) { $0 }
    return Harness(
      root: root, store: store, settings: context.settings, host: host,
      repository: repository, granted: isGranted, registry: registry)
  }

  // MARK: Without Full Disk Access

  @Test("Switched off while refused at its gate, with no instance, the index is deleted")
  func offWithNoInstance() async throws {
    let harness = try await harness(enabled: true, granted: false)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try await harness.plantIndex()

    try await harness.registry.startAll()
    #expect(await harness.registry.service(MessageSearchIndexService.id) == nil)
    #expect(await harness.store.exists, "switched on, so the index is not this start's to delete")

    try await harness.setSwitch(false)
    #expect(!(await harness.store.exists), "the index survived the switch going off")
    #expect(await harness.registry.service(MessageSearchIndexService.id) == nil)
    await harness.registry.stopAll()
  }

  @Test("Switched off while the server was down, it is deleted at the next start")
  func offBeforeLaunch() async throws {
    let harness = try await harness(enabled: false, granted: false)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try await harness.plantIndex()

    try await harness.registry.startAll()
    #expect(!(await harness.store.exists), "an install switched off while stopped kept its index")
    await harness.registry.stopAll()
  }

  @Test("Full Disk Access taken away from a running service, the switch still deletes")
  func offAfterRevocation() async throws {
    let harness = try await harness(enabled: true, granted: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try await harness.registry.startAll()
    try await waitUntil("the index to be built") {
      (try? await harness.store.isBackfillComplete()) == true
    }

    harness.granted.withLock { $0 = false }
    try await harness.setSwitch(false)
    #expect(!(await harness.store.exists))
    #expect(await harness.registry.service(MessageSearchIndexService.id) == nil)
    await harness.registry.stopAll()
  }

  // MARK: With it

  @Test("Switched off while running, the index is deleted and the service reports running")
  func offWhileRunning() async throws {
    // The onboarding copy says "turning it off deletes it". This is that sentence.
    let harness = try await harness(enabled: true, granted: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try await harness.registry.startAll()
    try await waitUntil("the index to be built") {
      (try? await harness.store.isBackfillComplete()) == true
    }

    try await harness.setSwitch(false)
    #expect(!(await harness.store.exists), "the index survived the switch going off")
    #expect(await harness.health == .running)
    await harness.registry.stopAll()
  }

  @Test("Switched off while its restart policy has it, the index is deleted")
  func offDuringARetry() async throws {
    // `chat.db` would not open, so the start threw and the instance is waiting out its backoff.
    // Not refused and not running, and it answers a settings change as a running one does.
    let harness = try await harness(enabled: true, granted: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try await harness.plantIndex()
    harness.host.readPath.withLock { $0 = nil }

    try await harness.registry.startAll()
    #expect(await harness.registry.isSupervising(MessageSearchIndexService.id))

    try await harness.setSwitch(false)
    #expect(!(await harness.store.exists))
    #expect(!(await harness.registry.isSupervising(MessageSearchIndexService.id)))
    await harness.registry.stopAll()
  }

  // MARK: Turning it back on

  @Test("Back on after being off, it builds from nothing rather than resuming")
  func backOnRebuildsFromNothing() async throws {
    let harness = try await harness(enabled: true, granted: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try await harness.plantIndex()
    try await harness.registry.startAll()
    #expect(try await harness.matches("zzqqxplantedword").isEmpty == false)

    try await harness.setSwitch(false)
    #expect(!(await harness.store.exists))

    try await harness.setSwitch(true)
    try await waitUntil("the index to be rebuilt") {
      (try? await harness.store.isBackfillComplete()) == true
    }
    #expect(try await harness.store.indexedCount() > 0)
    #expect(
      try await harness.matches("zzqqxplantedword").isEmpty,
      "the words of the deleted index came back")
    await harness.registry.stopAll()
  }

  @Test("Off and on again with no permission, then a grant, it builds from nothing")
  func backOnThenGranted() async throws {
    let harness = try await harness(enabled: true, granted: false)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try await harness.plantIndex()
    try await harness.registry.startAll()

    try await harness.setSwitch(false)
    #expect(!(await harness.store.exists))

    // On again, still refused: nothing to build from, and no file created to hold it.
    try await harness.setSwitch(true)
    #expect(!(await harness.store.exists))
    #expect(await harness.registry.service(MessageSearchIndexService.id) == nil)

    harness.granted.withLock { $0 = true }
    await harness.registry.permissionsGranted([.fullDiskAccess])
    try await waitUntil("the index to be rebuilt") {
      (try? await harness.store.isBackfillComplete()) == true
    }
    #expect(try await harness.store.indexedCount() > 0)
    #expect(try await harness.matches("zzqqxplantedword").isEmpty)
    await harness.registry.stopAll()
  }

  // MARK: What it must not delete

  @Test("Switched on and refused at the gate, the index is left alone")
  func onAndRefusedKeepsTheIndex() async throws {
    // The hazard in running this ahead of the gates: someone who has only lost Full Disk Access
    // for a moment did not ask to pay for the backfill again.
    let harness = try await harness(enabled: true, granted: false)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try await harness.plantIndex()

    try await harness.registry.startAll()
    #expect(await harness.store.exists)
    await harness.registry.restart(MessageSearchIndexService.id)
    #expect(await harness.store.exists)
    await harness.registry.stopAll()
    #expect(await harness.store.exists, "stopping the server is not switching the feature off")
  }

  // MARK: A database that opens late

  @Test("A retry finds a database that has opened since the instance was made")
  func retryReadsTheReadPathAgain() async throws {
    // The instance a restart policy retries is the one it made first. A repository captured
    // when it was made is nil for every attempt, however the database has moved on since, and
    // only Try Again's fresh instance recovered.
    let harness = try await harness(enabled: true, granted: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.host.readPath.withLock { $0 = nil }

    let service = MessageSearchIndexService(host: harness.host, store: harness.store)
    await #expect(throws: ServiceStartupError.self) { try await service.start() }
    await service.stop()

    harness.host.readPath.withLock { $0 = harness.repository }
    try await service.start()
    try await waitUntil("the index to be built") {
      (try? await harness.store.isBackfillComplete()) == true
    }
    await service.stop()
  }
}
