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

  /// REGRESSION. A secret was exempt from the whole rule.
  ///
  /// Its value lives in the Keychain rather than in `persisted`, so the change filter could
  /// not compare it and assumed it had moved. Every rewrite of an unchanged secret therefore
  /// announced a change, and a service watching its own fields restarts on one: zrok
  /// rewriting its unchanged `reserved_token` restarted zrok, which rewrote it, 175 times in
  /// 71 seconds against zrok's API. The comparison is made where `stageSecrets` has already
  /// read the previous value, so it costs no extra Keychain access.
  @Test("Rewriting the same SECRET announces nothing either")
  func sameSecretIsNotAChange() async throws {
    let store = try await store()
    try await store.set("s3cret", forKey: "app.example.service.token", isSecret: true)

    let second = try await store.write { batch in
      batch.setDynamic("s3cret", forKey: "app.example.service.token", isSecret: true)
    }
    #expect(
      second.changedKeys.isEmpty,
      "an unchanged secret announced a change, which is a restart to anything watching it")
  }

  @Test("A secret that really changes still announces")
  func changedSecretIsAChange() async throws {
    let store = try await store()
    try await store.set("first", forKey: "app.example.service.token", isSecret: true)

    let second = try await store.write { batch in
      batch.setDynamic("second", forKey: "app.example.service.token", isSecret: true)
    }
    #expect(second.changedKeys == ["app.example.service.token"])
  }

  /// Setting one for the first time is a change: there was nothing there before.
  @Test("A secret written where none was stored announces")
  func firstSecretIsAChange() async throws {
    let store = try await store()
    let change = try await store.write { batch in
      batch.setDynamic("first", forKey: "app.example.service.token", isSecret: true)
    }
    #expect(change.changedKeys == ["app.example.service.token"])
  }

  /// A batch carrying one moved key and one unmoved one announces only the mover, secrets
  /// included: the whole batch used to be announced because the secret was assumed moved.
  @Test("A mixed batch announces only what moved")
  func mixedBatchAnnouncesOnlyMovers() async throws {
    let store = try await store()
    try await store.set("s3cret", forKey: "app.example.service.token", isSecret: true)
    try await store.set(Settings.serverAddress, to: "https://one.trycloudflare.com")

    let change = try await store.write { batch in
      batch.setDynamic("s3cret", forKey: "app.example.service.token", isSecret: true)
      try batch.set(Settings.serverAddress, to: "https://two.trycloudflare.com")
    }
    #expect(change.changedKeys == [Settings.serverAddress.key])
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

  /// A secret follows the same rule as everything else, and this test used to assert the
  /// opposite.
  ///
  /// It read: "a secret carries no comparable value in its row, so it is always announced.
  /// Announcing a credential twice is harmless; failing to announce a rotated one is not."
  /// The first clause stopped being true when the comparison moved to where `stageSecrets`
  /// has already read the previous value, and the second turned out to be false: announcing
  /// a credential twice is a restart to every service watching that key, which for zrok's
  /// `reserved_token` was 175 restarts in 71 seconds. The half that was right is kept, one
  /// test down: a rotated secret still announces.
  @Test("A secret rewritten unchanged announces nothing")
  func unchangedSecretsAnnounceNothing() async throws {
    let store = try await store()
    try await store.set(Settings.password, to: "correct-horse-battery-staple")

    let second = try await store.write { batch in
      try batch.set(Settings.password, to: "correct-horse-battery-staple")
    }
    #expect(second.changedKeys.isEmpty)
  }

  /// The half of the old rule that was right, and the one that matters for a credential:
  /// a password that really changed must reach the services that authenticate with it.
  @Test("A rotated secret still announces")
  func rotatedSecretsAnnounce() async throws {
    let store = try await store()
    try await store.set(Settings.password, to: "correct-horse-battery-staple")

    let second = try await store.write { batch in
      try batch.set(Settings.password, to: "a-different-password")
    }
    #expect(second.changedKeys == [Settings.password.key])
  }
}
