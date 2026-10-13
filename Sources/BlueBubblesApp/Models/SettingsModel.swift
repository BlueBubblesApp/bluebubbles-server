//  SettingsModel
//  The one door from the app's screens to the server's settings: read, write, follow, and
//  keep what was typed and not yet saved.
//
//  A view reaches a setting through `model.settings` and nothing else. The failure this
//  prevents is a view holding an optional store and guarding on it: with no server such a
//  write did NOTHING and said nothing, so a switch flipped back, a Save did not save, and the
//  page gave no reason. Every call here throws `ServerNotRunning` instead, which
//  `DiagnosticText` renders as a sentence, so the caller always has something to show. And it
//  is ONE door, attached before the start delay: two that disagree for the length of the
//  delay make whether a screen works during one depend on which it picked.
//
//  **Writes run as the operator.** A view does not wrap them in `asOperator`;
//  `OperatorAttributionPolicyTests` accepts a call through `model.settings` because it reads
//  this file and checks that every writer here opens one.
//
//  **Following is here, never in a view.** The model follows the store for the life of the
//  server and counts changes per key; a view keys a `.task(id:)` on `version(of:)` and reads
//  again when it moves. The counters are one observable object per key (and per namespace),
//  so a write re-renders the views following THAT key and leaves the rest alone, which one
//  shared dictionary of versions would not.
//
//  **And an edit that was not committed is kept, not written.** A row torn down mid-edit
//  (another tab, another page) cannot show the error a write might produce, so it hands its
//  draft here and gets it back on its next appearance, still saying "Not saved yet". See
//  `keepDraft(_:typedOver:for:)`.
//
//  `ViewPlumbingPolicyTests` refuses `SettingsStore`, `settingsStore` and `.changes()` under
//  `Views/`, so this is the only way a screen reaches a setting.

import BBBuiltIns
import BBCore
import BBServiceKit
import BBSettings
import Foundation
import Observation

/// What a call answers when there is no server to ask: a settings read or write, or an
/// action that needs something only a running server has.
///
/// Thrown rather than returned as nil, because nil is what "nothing is stored" looks like,
/// and a page that cannot tell the two apart draws an empty field over a password that is
/// set. For an action the same reasoning is worse: `guard let x = model.y else { return }`
/// was a button that did nothing and said nothing.
struct ServerNotRunning: BBError {
  var code: String { "app.server_not_running" }
  var domain: String { "App" }
  var title: String { "The server is not running" }
  var body: String {
    "The server is not running, so this cannot be done. Start it, then try again."
  }
}

extension Optional {
  /// The value, or `ServerNotRunning`: the one way an action reaches something only a
  /// running server holds, so the refusal lands in whatever error slot the action has.
  func orServerNotRunning() throws -> Wrapped {
    guard let self else { throw ServerNotRunning() }
    return self
  }
}

@Observable
@MainActor
final class SettingsModel {

  /// The running server's store, from `attach` until `detach`. Private: a screen asks this
  /// model, never the store, which is what makes "no server" an answer rather than a no-op.
  private var store: SettingsStore?

  /// Whether there is a server to read from. A page shows `ServerStoppedNotice` while this
  /// is false rather than calls that would each throw.
  var isAvailable: Bool { store != nil }

  private let followTask = OwnedTask()
  @ObservationIgnored private var keyCounters: [String: ChangeCounter] = [:]
  @ObservationIgnored private var namespaceCounters: [String: ChangeCounter] = [:]
  @ObservationIgnored private var drafts: [String: KeptDraft] = [:]

  // MARK: - Lifetime

  /// Async so the subscription exists when this returns: a write landing between attaching
  /// and a task getting round to subscribing would otherwise be missed by every follower.
  func attach(_ store: SettingsStore) async {
    followTask.cancel()
    let changes = await store.changes()
    self.store = store
    // A server that has just started may hold different values from the one a follower
    // last read, so every follower reads once more.
    for counter in Array(keyCounters.values) + Array(namespaceCounters.values) {
      counter.value &+= 1
    }
    followTask.run { @MainActor [weak self] in
      for await change in changes {
        self?.noteChange(change.changedKeys)
      }
    }
  }

  /// Drops the store and everything kept for it. A draft typed against a server that has
  /// stopped is not an edit of whatever the next one holds.
  func detach() {
    followTask.cancel()
    store = nil
    drafts = [:]
  }

  private func requireStore() throws -> SettingsStore {
    guard let store else { throw ServerNotRunning() }
    return store
  }

  // MARK: - Reading

  func get<Value: SettingValue>(_ setting: Setting<Value>) async throws -> Value {
    try await requireStore().get(setting)
  }

  /// A secret, as a `SecureString` so a caller asking only whether one is set never holds
  /// it as a `String`. Nil when the Keychain could not be read; see `SettingsStore.secret`.
  func secret(_ setting: Setting<String>) async throws -> SecureString? {
    try await requireStore().secret(setting)
  }

  /// A row's value, through the layered resolution: an override reads back as the override.
  func read(_ setting: AnySetting) async throws -> SettingBox {
    try await setting.read(requireStore())
  }

  /// Where a row's value came from. Not for a secret: see `AnySetting.source`.
  func source(_ setting: AnySetting) async throws -> SettingSource {
    try await setting.source(requireStore())
  }

  /// What is known about a secret without reading it.
  func presence(_ setting: AnySetting) async throws -> SecretPresence {
    try await setting.presence(requireStore())
  }

  /// What is known about a manifest's secret field without reading it.
  func presence(ofSecretKey key: String) async throws -> SecretPresence {
    try await requireStore().presence(ofSecretKey: key)
  }

  /// A manifest field's stored value. For a secret field, this IS the read: call it on a
  /// click, never to draw the form.
  func string(forKey key: String) async throws -> String? {
    try await requireStore().string(forKey: key)
  }

  /// Whether the Keychain refused the last read of `key`.
  ///
  /// Asked, never inferred: a read that failed resolves to the declared default, which is
  /// exactly what a secret genuinely set to the empty string reads as.
  func isUnreadable(_ key: String) async throws -> Bool {
    try await requireStore().unreadableSecretKeys.contains(key)
  }

  /// The required fields a service has no value for, honouring `visibleWhen`.
  func missingRequiredFields(_ manifest: ServiceManifest) async throws -> [FieldDescriptor] {
    try await ServiceSettingsBridge.missingRequiredFields(manifest, store: requireStore())
  }

  // MARK: - Writing, as the operator

  func set<Value: SettingValue>(_ setting: Setting<Value>, to value: Value) async throws {
    let store = try requireStore()
    try await asOperator { try await store.set(setting, to: value) }
  }

  /// A row's write, validating first: a refusal throws the validator's own sentence.
  func write(_ setting: AnySetting, _ value: SettingBox) async throws {
    let store = try requireStore()
    try await asOperator { try await setting.write(store, value) }
  }

  /// A manifest field's write.
  func set(_ value: String, forKey key: String, isSecret: Bool) async throws {
    let store = try requireStore()
    try await asOperator { try await store.set(value, forKey: key, isSecret: isSecret) }
  }

  /// Several settings in one transaction.
  func write(_ batch: @escaping @Sendable (inout SettingsBatch) throws -> Void) async throws {
    let store = try requireStore()
    _ = try await asOperator { try await store.write(batch) }
  }

  /// Clears a service's stored settings and puts its manifest defaults back.
  ///
  /// - Returns: How many stored values were cleared.
  @discardableResult
  func reset(_ manifest: ServiceManifest) async throws -> Int {
    let store = try requireStore()
    return try await asOperator {
      try await ServiceSettingsBridge.resetToDefaults(manifest, store: store)
    }
  }

  // MARK: - Following

  /// Moves whenever any of `keys` is written, from anywhere: this app, the API, a service.
  ///
  /// For a `.task(id:)`: the task runs once when the view appears and again on every move.
  /// Read it only for keys the view actually follows, since reading it is what subscribes.
  func version(of keys: some Sequence<String>) -> UInt64 {
    keys.reduce(0) { $0 &+ counter(forKey: $1).value }
  }

  /// Moves whenever any key starting with `prefix` is written: a manifest's namespace, so a
  /// service gaining a field needs no change in the view following it.
  func version(inNamespace prefix: String) -> UInt64 {
    if let counter = namespaceCounters[prefix] { return counter.value }
    let counter = ChangeCounter()
    namespaceCounters[prefix] = counter
    return counter.value
  }

  /// Records a change the store announced. Internal for the tests; the follow task is the
  /// only other caller.
  ///
  /// Only counters something has asked for are moved: a key nobody follows needs no counter,
  /// and a follower that asks later starts from a fresh read anyway.
  func noteChange(_ keys: Set<String>) {
    for key in keys {
      keyCounters[key]?.value &+= 1
    }
    for (prefix, counter) in namespaceCounters where keys.contains(where: { $0.hasPrefix(prefix) })
    {
      counter.value &+= 1
    }
  }

  private func counter(forKey key: String) -> ChangeCounter {
    if let counter = keyCounters[key] { return counter }
    let counter = ChangeCounter()
    keyCounters[key] = counter
    return counter
  }

  // MARK: - Drafts

  /// Keeps an edit that was typed and not committed, for the view to take back when it
  /// appears again.
  ///
  /// Written down rather than written: the moment a view is torn down is the one moment it
  /// cannot show what a write refused, and a refused password sitting in nobody's field is
  /// the worst place for one. Kept, it comes back under "Not saved yet" where Return or
  /// clicking away commits it and a refusal is shown beside it.
  ///
  /// `base` is the stored value the edit was typed over; see `takeDraft`.
  func keepDraft(_ text: String, typedOver base: String, for key: String) {
    drafts[key] = KeptDraft(text: text, base: base)
  }

  /// The kept draft for `key`, if the stored value is still the one it was typed over.
  ///
  /// Taken either way, never left behind. A draft over a value that has since moved (a reset,
  /// the API, another screen) is an edit of something that is no longer there, and putting
  /// it back would write over the newer value on the next blur.
  func takeDraft(for key: String, ifStillOver base: String) -> String? {
    guard let kept = drafts.removeValue(forKey: key), kept.base == base else { return nil }
    return kept.text
  }

  /// Forgets a kept draft, once the edit has been committed.
  func discardDraft(for key: String) {
    drafts[key] = nil
  }
}

/// One key's change count, as its own observable object so that following one key does not
/// re-render on another.
@Observable
@MainActor
private final class ChangeCounter {
  var value: UInt64 = 0
}

private struct KeptDraft {
  let text: String
  let base: String
}
