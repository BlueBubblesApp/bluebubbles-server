//  WriteAtomicityTests
//  A batch either lands whole or does not land at all.
//
//  The failure this guards against is quiet rather than loud: a batch that persists its
//  first two keys, throws on the third, and never broadcasts. The store, the database and
//  every running service then disagree about the configuration, and nothing reports it —
//  the caller sees an error and reasonably assumes nothing happened.

import Foundation
import GRDB
import Testing

@testable import BBPersistence
@testable import BBSettings

/// A Keychain that fails on demand, which is the realistic way a batch fails partway: the
/// database write is local and reliable, the Keychain is the one that can refuse.
private final class FailingSecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: String] = [:]
  /// Keys that throw on `set`.
  var failing: Set<String> = []

  struct Refused: Error {}

  func get(_ key: String) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return storage[key]
  }

  func set(_ key: String, value: String) throws {
    if failing.contains(key) { throw Refused() }
    lock.lock()
    defer { lock.unlock() }
    storage[key] = value
  }

  func delete(_ key: String) throws {
    lock.lock()
    defer { lock.unlock() }
    storage[key] = nil
  }
}

@Suite("Settings write atomicity")
struct WriteAtomicityTests {

  private func makeStore(
    secrets: any SecretStore
  ) async throws -> SettingsStore {
    let database = try AppDatabase.inMemory()
    return try await SettingsStore(database: database, secrets: secrets)
  }

  @Test("A batch that fails partway leaves nothing behind")
  func failedBatchIsNotPartiallyApplied() async throws {
    let secrets = FailingSecretStore()
    secrets.failing = [Settings.password.key]
    let store = try await makeStore(secrets: secrets)

    let before = await store.get(Settings.socketPort)

    await #expect(throws: (any Error).self) {
      try await store.write { batch in
        try batch.set(Settings.socketPort, to: 4321)
        try batch.set(Settings.password, to: "hunter2hunter2")
      }
    }

    // The non-secret key was ordered FIRST in the batch, so under the old
    // one-transaction-per-operation write it would already be committed here.
    #expect(await store.get(Settings.socketPort) == before)
  }

  @Test("A failed batch restores the previous secret")
  func failedBatchRollsBackSecrets() async throws {
    let secrets = FailingSecretStore()
    let store = try await makeStore(secrets: secrets)

    try await store.set(Settings.password, to: "originalpassword")
    #expect(await store.secret(Settings.password)?.unsafeStringValue() == "originalpassword")

    // The second secret refuses, so the first has to be put back.
    secrets.failing = [Settings.ntfyToken.key]
    await #expect(throws: (any Error).self) {
      try await store.write { batch in
        try batch.set(Settings.password, to: "replacementpassword")
        try batch.set(Settings.ntfyToken, to: "token")
      }
    }

    #expect(await store.secret(Settings.password)?.unsafeStringValue() == "originalpassword")
  }

  @Test("A rejected value stops the whole batch, not just its own key")
  func validationRejectsTheWholeBatch() async throws {
    let store = try await makeStore(secrets: InMemorySecretStore())

    await #expect(throws: (any Error).self) {
      try await store.write { batch in
        try batch.set(Settings.socketPort, to: 4321)
        // Below the entropy floor the policy enforces.
        try batch.set(Settings.password, to: "a")
      }
    }
    #expect(await store.get(Settings.socketPort) == 1234)
  }

  @Test("A successful batch emits exactly one change naming every key")
  func batchEmitsOneChange() async throws {
    // The N-cascading-restarts fix. A UI save touching five keys must produce one
    // change, or five services restart five times each.
    let store = try await makeStore(secrets: InMemorySecretStore())

    let change = try await store.write { batch in
      try batch.set(Settings.socketPort, to: 4321)
      try batch.set(Settings.dbPollInterval, to: 2000)
      try batch.set(Settings.autoCaffeinate, to: true)
    }

    #expect(change.changedKeys == ["socket_port", "db_poll_interval", "auto_caffeinate"])
  }

  @Test("An empty batch changes nothing and announces nothing")
  func emptyBatchIsSilent() async throws {
    let store = try await makeStore(secrets: InMemorySecretStore())
    let change = try await store.write { _ in }
    #expect(change.changedKeys.isEmpty)
  }

}
