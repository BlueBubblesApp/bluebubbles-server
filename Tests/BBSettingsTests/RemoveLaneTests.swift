//  RemoveLaneTests
//  A removal and a write to the same key cannot interleave.
//
//  `SettingsStore.remove` deletes the row, awaits, and then deletes the Keychain half. A
//  secret write landing in that await staged its new value in the Keychain before its own
//  row was written, and the removal then deleted that value: the marker row said a secret
//  was stored and the Keychain held nothing. Both now take the one write lane.
//
//  The window is held open deterministically: the database writer is parked on a semaphore,
//  so the removal is suspended inside its row delete while the write is started.

import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBPersistence
@testable import BBSettings

/// A Keychain double that says when a value has been staged into it.
private final class ObservedSecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: String] = [:]
  private var staged = false

  func get(_ key: String) throws -> String? {
    lock.withLock { storage[key] }
  }

  func set(_ key: String, value: String) throws {
    lock.withLock {
      storage[key] = value
      staged = true
    }
  }

  func delete(_ key: String) throws {
    lock.withLock { storage[key] = nil }
  }

  var hasStaged: Bool { lock.withLock { staged } }
  func resetStaged() { lock.withLock { staged = false } }
}

@Suite("Settings remove lane")
struct RemoveLaneTests {

  @Test("A secret written while a removal is in flight is not deleted by it")
  func removalDoesNotDeleteAConcurrentWrite() async throws {
    let key = "app.bluebubbles.test.token"
    let database = try AppDatabase.inMemory(contributors: [SettingsSchema.self])
    let secrets = ObservedSecretStore()
    let store = try await TestSettings.store(database: database, secrets: secrets)
    try await store.set("old", forKey: key, isSecret: true)
    secrets.resetStaged()

    // Park the database writer so the removal suspends inside its row delete.
    let release = DispatchSemaphore(value: 0)
    await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
      Thread {
        _ = try? database.writeSynchronously { _ in
          entered.resume()
          release.wait()
        }
      }.start()
    }

    let removal = Task { try await store.remove(forKey: key) }
    // Long enough for the removal to reach the parked writer; the assertion below holds
    // whichever order the two end up in, so this only makes the broken order likely.
    try await Task.sleep(for: .milliseconds(50))
    let write = Task { try await store.set("new", forKey: key, isSecret: true) }

    // Outside the lane the write stages its secret now, during the removal's await. Inside
    // it, the write is queued and nothing is staged until the removal has finished.
    for _ in 0..<30 where !secrets.hasStaged {
      try await Task.sleep(for: .milliseconds(10))
    }
    release.signal()
    try await removal.value
    try await write.value

    // Whichever order the two ran in, the marker row and the Keychain must agree.
    let rowExists = try await database.read { db in
      try Bool.fetchOne(
        db, sql: "SELECT EXISTS(SELECT 1 FROM setting WHERE key = ?)", arguments: [key])
        ?? false
    }
    let stored = try secrets.get(key)
    #expect(rowExists == (stored != nil), "row: \(rowExists), secret stored: \(stored != nil)")
    // And with the removal started first, the write is the last word.
    #expect(stored == "new")
  }
}
