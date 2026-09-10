//  NoOpWriteTests
//  Writing the value that is already stored is not a change, and must not be announced as one.
//
//  Every connection method republishes `server_address` on each connect and each reconnect,
//  and a broadcast per publish is what turns a routine republish into a restart. Suppressing
//  the no-op is the second guard against that; the first is a service not restarting on a key
//  it consumes live (`HTTPService.liveKeys`). Both are needed: this one holds when the value
//  is unchanged, and that one holds when a tunnel comes back with a genuinely new address.
//
//  See `.claude/docs/architecture.md`.

import Foundation
import Testing

@testable import BBPersistence
@testable import BBSettings

@Suite("No-op writes")
struct NoOpWriteTests {

  private func store() async throws -> SettingsStore {
    try await SettingsStore(
      database: try AppDatabase.inMemory(contributors: [SettingsSchema.self]),
      secrets: InMemorySecretStore()
    )
  }

  @Test("Rewriting the same value announces nothing")
  func sameValueIsNotAChange() async throws {
    let store = try await store()
    try await store.set(Settings.serverAddress, to: "https://example.trycloudflare.com")

    let second = try await store.write { batch in
      try batch.set(Settings.serverAddress, to: "https://example.trycloudflare.com")
    }
    #expect(second.changedKeys.isEmpty)
  }

  @Test("A genuinely new value still announces")
  func newValueIsAChange() async throws {
    let store = try await store()
    try await store.set(Settings.serverAddress, to: "https://one.trycloudflare.com")

    let second = try await store.write { batch in
      try batch.set(Settings.serverAddress, to: "https://two.trycloudflare.com")
    }
    #expect(second.changedKeys == [Settings.serverAddress.key])
  }

  /// A batch is filtered per key, not accepted or dropped whole; otherwise one unchanged
  /// value in a Save would suppress the four beside it that did move.
  @Test("A mixed batch announces only the keys that moved")
  func mixedBatchAnnouncesOnlyWhatMoved() async throws {
    let store = try await store()
    try await store.write { batch in
      try batch.set(Settings.serverAddress, to: "https://one.trycloudflare.com")
      try batch.set(Settings.socketPort, to: 1234)
    }

    let second = try await store.write { batch in
      try batch.set(Settings.serverAddress, to: "https://one.trycloudflare.com")
      try batch.set(Settings.socketPort, to: 4321)
    }
    #expect(second.changedKeys == [Settings.socketPort.key])
  }

  /// The first write of a key is always a change, including one whose value happens to equal
  /// the declared default; nothing was stored before it.
  @Test("The first write announces even when it matches the default")
  func firstWriteAnnounces() async throws {
    let store = try await store()
    let change = try await store.write { batch in
      try batch.set(Settings.socketPort, to: Settings.socketPort.defaultValue)
    }
    #expect(change.changedKeys == [Settings.socketPort.key])
  }

  /// A secret carries no comparable value in its row, so it is always announced. Announcing
  /// a credential twice is harmless; failing to announce a rotated one is not.
  @Test("A secret is announced even when rewritten unchanged")
  func secretsAlwaysAnnounce() async throws {
    let store = try await store()
    try await store.set(Settings.password, to: "correct-horse-battery-staple")

    let second = try await store.write { batch in
      try batch.set(Settings.password, to: "correct-horse-battery-staple")
    }
    #expect(second.changedKeys == [Settings.password.key])
  }
}
