//  SettingsStore
//  Typed, layered, transactional settings.
//
//  Three problems it fixes:
//    1. Values carry an explicit type tag, so nothing is inferred. The current store infers
//       from the string: "1"/"0" become Bool, /^-?\d+$/ becomes Number. A numeric setting
//       whose value happens to be 0 or 1 comes back as a boolean.
//    2. Sources are layered rather than flattened into the database. CLI arguments no longer
//       get WRITTEN to the DB, which is what `--persist-config` exists to undo.
//    3. Writes are transactional. A batch emits ONE change, so a single Save in the UI
//       cannot fire N cascading service restarts the way the per-key setConfig loop does.
//
//  See `.claude/docs/database.md`.

import BBCore
import BBDiagnostics
import BBPersistence
import Foundation
import GRDB
import Logging

/// A resolved value plus where it came from.
public struct ResolvedSetting<Value: SettingValue>: Sendable {
  public let value: Value
  public let source: SettingSource
}

public actor SettingsStore {

  private let database: AppDatabase
  private let secrets: any SecretStore
  private let logger = Logger(label: "bluebubbles.settings")

  /// Layers above the persisted store, highest precedence last. Read-only at runtime:
  /// a `write` always targets the persisted layer, so a CLI override is never clobbered
  /// by a UI save and never silently persisted either.
  private let configFileValues: [String: String]
  private let commandLineValues: [String: String]

  /// Decoded persisted values, read through on every access. Small enough to hold whole.
  private var persisted: [String: StoredValue] = [:]

  private var continuations: [UUID: AsyncStream<SettingsChange>.Continuation] = [:]

  /// Attached after construction, because the alert centre is built later than storage is.
  /// Failures seen before it arrives are held in `pendingAlerts` and raised on attach, so a
  /// Keychain that is unreadable during start-up — the likeliest moment for it to be — is
  /// not the one case that goes unreported.
  private var alerts: (any AlertRaising)?
  private var pendingAlerts: [SettingsError] = []

  /// Keys whose last Keychain read failed. Two jobs: it stops a per-request read from
  /// spawning a raise every time, and it lets a caller tell "this secret is empty" from
  /// "this secret could not be read", which otherwise look identical from the outside.
  private var unreadableSecrets: Set<String> = []

  struct StoredValue: Sendable {
    let json: Data
    let typeTag: String
    let isSecret: Bool
  }

  public init(
    database: AppDatabase,
    secrets: any SecretStore,
    configFileValues: [String: String] = [:],
    commandLineValues: [String: String] = [:]
  ) async throws {
    self.database = database
    self.secrets = secrets
    self.configFileValues = configFileValues
    self.commandLineValues = commandLineValues
    try await load()
  }

  // MARK: - Schema
  //
  // The `setting` table is created by `AppDatabase.migrate()`, which owns every migration
  // for this database. There used to be a second, byte-identical `createSettings`
  // registration here — public, called by nothing, and holding its own copy of the schema.
  // Two definitions of one table under the same migration identifier is a silent drift
  // hazard: editing either one leaves the other stale with nothing to catch it.
  //
  // Note the explicit `type_tag` column over there: it is what removes the guessing.

  private func load() async throws {
    // Mapped INSIDE the read closure, because `Row` borrows the statement's storage and
    // is not `Sendable`. Returning rows from here is now a compile error rather than the
    // silent fallback to GRDB's synchronous overload it used to be — see `AppDatabase.queue`.
    persisted = try await database.read { db in
      var loaded: [String: StoredValue] = [:]
      for row in try Row.fetchAll(db, sql: "SELECT key, value, type_tag, is_secret FROM setting") {
        let key: String = row["key"]
        loaded[key] = StoredValue(
          json: row["value"],
          typeTag: row["type_tag"],
          isSecret: row["is_secret"]
        )
      }
      return loaded
    }
  }

  // MARK: - Alerts

  /// Hands the store somewhere to report to, and drains anything that failed before it existed.
  public func attachAlerts(_ alerts: any AlertRaising) async {
    self.alerts = alerts
    let pending = pendingAlerts
    pendingAlerts.removeAll()
    for error in pending { await alerts.raise(error, actions: []) }
  }

  /// Keys whose most recent Keychain read failed, for callers that must not present an
  /// unreadable secret as an unset one — the settings screen above all, where a password
  /// shown as blank invites the user to reset a password that was never actually lost.
  public var unreadableSecretKeys: Set<String> { unreadableSecrets }

  // MARK: - Reading

  /// The three distinct outcomes of reading a secret.
  ///
  /// `try? secrets.get(key)` collapsed the last two, and that collapse was the bug: a
  /// Keychain that is locked, or whose ACL the app no longer satisfies, became
  /// indistinguishable from one holding nothing. The server password then resolved to the
  /// declared default of "" and every client was turned away with
  /// `serverMisconfigured("Failed to retrieve password from the database")` — fail-closed,
  /// but naming a subsystem that was working perfectly. `SettingsError.keychainUnavailable`
  /// already existed, already declared itself `isUserFacing`, and could never reach the
  /// alert centre because no read site propagated it.
  enum SecretRead {
    case value(String)
    /// No such item. A password that has genuinely never been set.
    case absent
    /// The Keychain refused. The value may well exist; we cannot see it.
    case unreadable
  }

  func readSecret(_ key: String) -> SecretRead {
    do {
      let value = try secrets.get(key)
      // A read that works re-arms the alert, so a Keychain that fails, is fixed, and
      // fails again is reported the second time too.
      unreadableSecrets.remove(key)
      guard let value else { return .absent }
      return .value(value)
    } catch {
      let failure =
        (error as? SettingsError)
        // -1 only if a store other than the Keychain one throws something
        // unexpected; `Security` is not imported here, and BBSettings builds on Linux.
        ?? SettingsError.keychainUnavailable(key: key, status: -1)
      // Raise once per key per episode. `resolve` runs on the authentication path, so
      // without this latch a locked Keychain would spawn a Task per request; the alert
      // centre would coalesce them by code, but only after the work had been done.
      if unreadableSecrets.insert(key).inserted {
        if let alerts {
          Task { await alerts.raise(failure, actions: []) }
        } else {
          pendingAlerts.append(failure)
        }
      }
      logger.error(
        "Keychain read failed",
        metadata: [
          "key": .string(key),
          "error": .string(String(describing: failure)),
        ])
      return .unreadable
    }
  }

  public func get<Value: SettingValue>(_ setting: Setting<Value>) -> Value {
    resolve(setting).value
  }

  // MARK: - Dynamic keys
  //
  // Settings declared at RUNTIME rather than compiled in — a service's or plugin's own
  // fields, which arrive from its manifest. They cannot go through `Setting<Value>` because
  // that is a compile-time descriptor and a plugin's fields are data, so these take the key
  // directly.
  //
  // Deliberately NOT a general-purpose escape hatch: the caller is expected to be a
  // `SettingsScope`, which is what decides whether the key may be touched at all. Reaching
  // for these to bypass a declared setting would be missing the point of both.

  /// A dynamically-keyed value, or nil when it has never been set.
  ///
  /// Command line and config file still win, so a plugin's field can be overridden the same
  /// way a core setting can — which matters for support ("run it once with X set") and for
  /// tests.
  public func string(forKey key: String) -> String? {
    if let raw = commandLineValues[key] { return raw }
    if let raw = configFileValues[key] { return raw }

    if let stored = persisted[key] {
      if stored.isSecret {
        switch readSecret(key) {
        case .value(let secret): return secret
        // Both give back nil, but only one of them has alerted first.
        case .absent, .unreadable: return nil
        }
      }
      if let value = try? JSONDecoder().decode(String.self, from: stored.json) {
        return value
      }
      // A value stored as some other type still has a readable form — a toggle is
      // "true"/"false" to a form. Returning nil for it would make a boolean field look
      // unset the moment it was saved.
      return String(decoding: stored.json, as: UTF8.self)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    // A secret with no marker row, the shape the legacy migration produces.
    if case .value(let secret) = readSecret(key), !secret.isEmpty { return secret }
    return nil
  }

  /// Removes a dynamically-keyed value entirely.
  ///
  /// A real delete, not a write of `""`. The two are indistinguishable to most readers —
  /// `string(forKey:)` gives back an empty string either way — but they are not the same
  /// thing: an empty row means "configured, to nothing", and it survives as a row that
  /// declared defaults will then decline to fill, because something is already there. Reset
  /// has to leave the service looking untouched, which means the key must not exist.
  public func remove(forKey key: String) async throws {
    try await database.write { db in
      try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
    }
    persisted.removeValue(forKey: key)
    // The Keychain half too, or a cleared credential lingers where only the marker row
    // was removed — invisible, and still readable by anything that knows the key.
    try? secrets.delete(key)
    broadcast(SettingsChange(changedKeys: [key]))
  }

  /// Writes a dynamically-keyed value.
  ///
  /// `isSecret` decides the Keychain rather than a declaration, because for a plugin field
  /// the manifest is the only place that fact exists.
  public func set(_ value: String, forKey key: String, isSecret: Bool = false) async throws {
    let change = try await write { batch in
      batch.setDynamic(value, forKey: key, isSecret: isSecret)
    }
    _ = change
  }

  public func resolve<Value: SettingValue>(_ setting: Setting<Value>) -> ResolvedSetting<Value> {
    // Highest precedence first.
    if let raw = commandLineValues[setting.key], let value = decodeLoose(raw, as: Value.self) {
      return ResolvedSetting(value: value, source: .commandLine)
    }
    if let raw = configFileValues[setting.key], let value = decodeLoose(raw, as: Value.self) {
      return ResolvedSetting(value: value, source: .configFile)
    }
    // A declared secret is resolved from the Keychain WITHOUT requiring a marker row.
    // The legacy migration moves secrets straight into the Keychain and deliberately
    // leaves the database row out, so keying on the row made a migrated install report
    // that it had no server password — while authentication, which reads the Keychain
    // directly, worked fine. The two views of the same value have to agree.
    if setting.isSecret {
      if case .value(let secret) = readSecret(setting.key), !secret.isEmpty,
        let value = secret as? Value
      {
        return ResolvedSetting(value: value, source: .persistedStore)
      }
      // An unreadable secret still resolves to the default here, because `resolve`
      // has nowhere to put "unknown" — but it has alerted, and `unreadableSecretKeys`
      // now says so, which is what a caller needs to avoid presenting it as unset.
      return ResolvedSetting(value: setting.defaultValue, source: .declaredDefault)
    }

    if let stored = persisted[setting.key] {
      if stored.isSecret {
        if case .value(let secret) = readSecret(setting.key),
          let value = secret as? Value
        {
          return ResolvedSetting(value: value, source: .persistedStore)
        }
      } else if stored.typeTag == Value.typeTag,
        let value = try? JSONDecoder().decode(Value.self, from: stored.json)
      {
        return ResolvedSetting(value: value, source: .persistedStore)
      } else if stored.typeTag != Value.typeTag {
        // Recorded rather than silently coerced — coercion is the bug being fixed.
        logger.warning(
          "Stored type mismatch; using default",
          metadata: [
            "key": .string(setting.key),
            "expected": .string(Value.typeTag),
            "found": .string(stored.typeTag),
          ])
      }
    }
    return ResolvedSetting(value: setting.defaultValue, source: .declaredDefault)
  }

  /// Secrets are returned as `SecureString`, never as a plain String, so the caller has to
  /// opt in to materialising it.
  ///
  /// `nil` means the Keychain could not be read, and is deliberately NOT the same as the
  /// empty `SecureString` returned for a secret that is merely unset. The authentication
  /// path rejects both, but only one of them is the user's fault: conflating them is what
  /// made a Keychain failure surface as a claim about the database.
  public func secret(_ setting: Setting<String>) -> SecureString? {
    precondition(setting.isSecret, "\(setting.key) is not declared as a secret")
    if let raw = commandLineValues[setting.key] { return SecureString(raw) }
    if let raw = configFileValues[setting.key] { return SecureString(raw) }
    switch readSecret(setting.key) {
    case .value(let value): return SecureString(value)
    case .absent: return SecureString(setting.defaultValue)
    case .unreadable: return nil
    }
  }

  // MARK: - Writing

  /// Writes one setting. Prefer `write { }` for anything touching more than one key.
  public func set<Value: SettingValue>(_ setting: Setting<Value>, to value: Value) async throws {
    try await write { batch in
      try batch.set(setting, to: value)
    }
  }

  /// Applies a batch and emits exactly one change.
  ///
  /// This is what stops a UI Save touching five keys from producing five restart cascades.
  @discardableResult
  public func write(_ body: (inout SettingsBatch) throws -> Void) async throws -> SettingsChange {
    var batch = SettingsBatch()
    try body(&batch)
    guard !batch.operations.isEmpty else { return SettingsChange(changedKeys: []) }

    // Every operation is validated before ANY of them is applied. Validating inside the
    // apply loop instead would persist operations 1..n-1 and then throw on n, leaving the
    // store half-written — which is the exact failure this batching API exists to prevent.
    for operation in batch.operations {
      try operation.validate()
    }

    // Bound out of the Operations before the database closure below. `Operation` holds a
    // validate closure and so is not Sendable; these fields are, and they are all the
    // writes actually need. Capturing the Operation whole would be a data race the
    // compiler is right to reject.
    struct Row: Sendable {
      let key: String
      let typeTag: String
      let isSecret: Bool
      /// Empty for a secret: the row records only THAT one exists, never its value.
      let json: Data
    }
    let rows = batch.operations.map {
      Row(
        key: $0.key, typeTag: $0.typeTag, isSecret: $0.isSecret,
        json: $0.isSecret ? Data() : $0.encodedValue
      )
    }

    // Keychain first, remembering what was there. It is the one store that cannot join
    // the database transaction, so it is applied where it can still be undone: if the
    // transaction below fails, these are put back and the caller sees a write that did
    // nothing rather than one that half-happened.
    var restore: [(key: String, previous: String?)] = []
    do {
      for operation in batch.operations where operation.isSecret {
        // `try`, not `try?`. A swallowed read recorded `nil` — "there was nothing
        // here before" — so a rollback after an unreadable Keychain DELETED the
        // existing secret rather than restoring it. Failing the write instead is
        // also the right call on its own terms: a Keychain we cannot read is not
        // one we should be writing to.
        restore.append((operation.key, try secrets.get(operation.key)))
        try secrets.set(operation.key, value: operation.secretValue ?? "")
      }
    } catch {
      rollBackSecrets(restore)
      throw error
    }

    // ONE transaction for the whole batch. Previously each operation ran in its own,
    // so a failure partway through committed the earlier keys AND skipped the change
    // broadcast — leaving services configured from a state nobody was told about.
    let now = Date()
    do {
      try await database.write { db in
        for row in rows {
          try db.execute(
            sql: """
              INSERT INTO setting (key, value, type_tag, is_secret, updated_at)
              VALUES (?, ?, ?, ?, ?)
              ON CONFLICT(key) DO UPDATE SET value = excluded.value,
                  type_tag = excluded.type_tag, is_secret = excluded.is_secret,
                  updated_at = excluded.updated_at
              """,
            arguments: [row.key, row.json, row.typeTag, row.isSecret, now]
          )
        }
      }
    } catch {
      rollBackSecrets(restore)
      throw error
    }

    // The in-memory view is updated only once the durable write has committed, so a
    // failed transaction cannot leave `resolve` reporting a value that is not stored.
    for row in rows {
      persisted[row.key] = StoredValue(
        json: row.json, typeTag: row.typeTag, isSecret: row.isSecret
      )
    }

    let change = SettingsChange(changedKeys: Set(rows.map(\.key)))
    broadcast(change)
    return change
  }

  /// Best-effort undo of the Keychain half of a failed batch.
  ///
  /// Best-effort because a Keychain that just refused a write may refuse the undo too.
  /// Failing loudly here would replace one problem with a worse one — the caller already
  /// has an error to report, and the durable store is untouched either way.
  private func rollBackSecrets(_ restore: [(key: String, previous: String?)]) {
    for entry in restore.reversed() {
      if let previous = entry.previous {
        try? secrets.set(entry.key, value: previous)
      } else {
        try? secrets.delete(entry.key)
      }
    }
  }

  // MARK: - Observation

  public func changes() -> AsyncStream<SettingsChange> {
    let id = UUID()
    return AsyncStream { continuation in
      continuations[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeContinuation(id) }
      }
    }
  }

  private func removeContinuation(_ id: UUID) { continuations[id] = nil }

  private func broadcast(_ change: SettingsChange) {
    for continuation in continuations.values { continuation.yield(change) }
  }

  /// Loose decoding for the string-shaped layers (YAML, CLI), which have no type tags.
  private func decodeLoose<Value: SettingValue>(_ raw: String, as type: Value.Type) -> Value? {
    if let value = raw as? Value { return value }
    if type == Bool.self {
      switch raw.lowercased() {
      case "1", "true", "yes": return true as? Value
      case "0", "false", "no": return false as? Value
      default: return nil
      }
    }
    if type == Int.self { return Int(raw) as? Value }
    if type == Double.self { return Double(raw) as? Value }
    // Enum-backed settings decode from their raw string.
    if let data = "\"\(raw)\"".data(using: .utf8),
      let value = try? JSONDecoder().decode(Value.self, from: data)
    {
      return value
    }
    return nil
  }
}

/// Accumulates writes so a batch is applied and announced atomically.
public struct SettingsBatch {

  struct Operation {
    let key: String
    let typeTag: String
    let isSecret: Bool
    let encodedValue: Data
    let secretValue: String?
    let validate: () throws -> Void
  }

  private(set) var operations: [Operation] = []

  /// Writes a dynamically-keyed value — a service or plugin field from a manifest.
  ///
  /// No validator, because a manifest field has none to run: its constraints live in the
  /// `FieldKind` and are enforced by the form that produced the value. Anything stricter
  /// belongs in the service's own `start`, where it can report a reason.
  public mutating func setDynamic(_ value: String, forKey key: String, isSecret: Bool) {
    operations.append(
      Operation(
        key: key,
        typeTag: String.typeTag,
        isSecret: isSecret,
        encodedValue: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8),
        secretValue: isSecret ? value : nil,
        validate: {}
      )
    )
  }

  public mutating func set<Value: SettingValue>(_ setting: Setting<Value>, to value: Value) throws {
    let encoded = try JSONEncoder().encode(value)
    operations.append(
      Operation(
        key: setting.key,
        typeTag: Value.typeTag,
        isSecret: setting.isSecret,
        encodedValue: encoded,
        secretValue: setting.isSecret ? (value as? String) : nil,
        validate: { try setting.validate?(value) }
      )
    )
  }
}

/// The set of keys that changed. Deliberately not the whole settings object: services react
/// to what moved, and the registry routes on the intersection.
public struct SettingsChange: Sendable, Equatable {
  public let changedKeys: Set<String>
  public init(changedKeys: Set<String>) { self.changedKeys = changedKeys }
  public func contains(_ key: String) -> Bool { changedKeys.contains(key) }
  public func intersects(_ keys: Set<String>) -> Bool { !changedKeys.isDisjoint(with: keys) }
}
