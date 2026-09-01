import BBCore
import BBDiagnostics
import Foundation
import GRDB
import Testing

@testable import BBPersistence
@testable import BBSettings

/// A Keychain that refuses, which is what a locked login keychain or a signature the item's
/// ACL no longer trusts actually looks like from here.
///
/// `InMemorySecretStore` cannot express this — it only ever succeeds — which is why the
/// swallowed-error behaviour survived as long as it did: every test agreed with the code.
final class UnreadableSecretStore: SecretStore, @unchecked Sendable {

  /// `errSecInteractionNotAllowed`. The status a locked keychain returns with no UI to prompt.
  static let interactionNotAllowed: Int32 = -25308

  private let lock = NSLock()
  private var storage: [String: String] = [:]
  private var failing: Bool

  init(seed: [String: String] = [:], failing: Bool = true) {
    storage = seed
    self.failing = failing
  }

  func setFailing(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    failing = value
  }

  func get(_ key: String) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    if failing {
      throw SettingsError.keychainUnavailable(key: key, status: Self.interactionNotAllowed)
    }
    return storage[key]
  }

  func set(_ key: String, value: String) throws {
    lock.lock()
    defer { lock.unlock() }
    if failing {
      throw SettingsError.keychainUnavailable(key: key, status: Self.interactionNotAllowed)
    }
    storage[key] = value
  }

  func delete(_ key: String) throws {
    lock.lock()
    defer { lock.unlock() }
    storage[key] = nil
  }
}

actor RecordingAlerts: AlertRaising {
  private(set) var raised: [any BBError] = []
  private(set) var alerts: [UserAlert] = []

  func raise(_ alert: UserAlert) async { alerts.append(alert) }
  func raise(_ error: any BBError, actions: [AlertAction]) async { raised.append(error) }

  /// Waits for a count rather than sleeping for a guessed interval.
  ///
  /// The store dispatches its raise into an unstructured `Task`, so there is no point at
  /// which the caller can know it has landed. A fixed sleep passed in isolation and failed
  /// under a full-suite run, which is the usual way that bargain ends.
  func waitForRaised(_ count: Int, timeout: Duration = .seconds(2)) async -> [any BBError] {
    let deadline = ContinuousClock.now + timeout
    while raised.count < count, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(5))
    }
    return raised
  }
}

@Suite("An unreadable Keychain is not an empty one")
struct UnreadableSecretTests {

  private func makeStore(
    _ secrets: any SecretStore
  ) async throws -> SettingsStore {
    let database = try AppDatabase.inMemory()
    return try await SettingsStore(database: database, secrets: secrets)
  }

  /// The regression that motivated all of this. `secret()` returned an empty `SecureString`
  /// for a Keychain that could not be read, which the auth path could not tell from a
  /// password that was never set — so a Keychain failure was reported to every client as
  /// "Failed to retrieve password from the database".
  @Test("A failed read gives nil, not an empty secret")
  func unreadableIsNotEmpty() async throws {
    let store = try await makeStore(UnreadableSecretStore())
    #expect(await store.secret(Settings.password) == nil)
  }

  @Test("An unset secret still gives the declared default")
  func absentIsStillDefault() async throws {
    let store = try await makeStore(InMemorySecretStore())
    let value = await store.secret(Settings.password)
    #expect(value != nil)
    #expect(value?.isEmpty == true)
  }

  @Test("A failed read raises a user-facing alert")
  func failureAlerts() async throws {
    let store = try await makeStore(UnreadableSecretStore())
    let alerts = RecordingAlerts()
    await store.attachAlerts(alerts)

    _ = await store.secret(Settings.password)

    let raised = await alerts.waitForRaised(1)
    #expect(raised.count == 1)
    #expect(raised.first?.code == "settings.keychain_unavailable")
    #expect(raised.first?.isUserFacing == true)
  }

  /// The alert centre is built after the settings store, so the failure likeliest to
  /// matter — one during start-up — happens when there is nowhere to report it yet.
  @Test("A failure before the alert centre exists is raised on attach")
  func failureBeforeAttachIsHeld() async throws {
    let store = try await makeStore(UnreadableSecretStore())
    _ = await store.secret(Settings.password)

    let alerts = RecordingAlerts()
    await store.attachAlerts(alerts)

    // No wait needed: `attachAlerts` drains inline, before it returns.
    #expect(await alerts.raised.count == 1)
  }

  /// `resolve` runs on the authentication path. Without the latch, a locked Keychain would
  /// raise once per request.
  @Test("Repeated failures on one key raise once")
  func repeatedFailuresCoalesce() async throws {
    let store = try await makeStore(UnreadableSecretStore())
    let alerts = RecordingAlerts()
    await store.attachAlerts(alerts)

    for _ in 0..<10 { _ = await store.secret(Settings.password) }

    // Wait for the first, then confirm no second one follows it.
    #expect(await alerts.waitForRaised(1).count == 1)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await alerts.raised.count == 1)
    #expect(await store.unreadableSecretKeys.contains(Settings.password.key))
  }

  /// A Keychain that fails, is fixed, and fails again must report the second time too.
  @Test("A successful read re-arms the alert")
  func recoveryReArms() async throws {
    let secrets = UnreadableSecretStore(seed: ["password": "hunter2"])
    let store = try await makeStore(secrets)
    let alerts = RecordingAlerts()
    await store.attachAlerts(alerts)

    _ = await store.secret(Settings.password)
    secrets.setFailing(false)
    #expect(await store.secret(Settings.password)?.unsafeStringValue() == "hunter2")
    #expect(await store.unreadableSecretKeys.isEmpty)

    secrets.setFailing(true)
    _ = await store.secret(Settings.password)

    #expect(await alerts.waitForRaised(2).count == 2)
  }

  /// A swallowed read recorded "there was nothing here before", so rolling back a failed
  /// write DELETED the existing secret instead of restoring it.
  @Test("A write is refused when the previous value cannot be read")
  func writeRefusedOnUnreadableKeychain() async throws {
    let store = try await makeStore(UnreadableSecretStore(seed: ["password": "original"]))

    await #expect(throws: SettingsError.self) {
      try await store.set(Settings.password, to: "replacement")
    }
  }
}
