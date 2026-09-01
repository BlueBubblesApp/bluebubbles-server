//  ScopedSettings
//  A service's settings store, narrowed to what its manifest declares.
//
//  The manifest says what a service may touch; this is what makes saying it matter. Handed to
//  a service at construction, it answers reads and writes that are permitted and THROWS on the
//  ones that are not — never returning nil, because a nil is indistinguishable from "unset"
//  and would put the caller straight back into the silent-inertness failure this whole model
//  exists to end.
//
//  Two honest limits, stated here rather than discovered later:
//
//    - **Built-in services are trusted with the core configuration.** They are compiled into
//      this binary and can open `app.db` directly, so pretending to contain them would be
//      theatre. What they are NOT trusted with is credentials: `checkRead` refuses a secret
//      before it considers whether the caller is built-in.
//    - **This is a declaration that can be checked, not a sandbox.** It becomes a real
//      boundary only for the out-of-process plugins § 12 specifies, where the host answers
//      each request over RPC and can simply decline.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import BBHandlers
import BBInterfaces
import BBServiceKit
import BBSettings
import Foundation

public struct ScopedSettings: Sendable {

  private let store: SettingsStore
  private let scope: SettingsScope
  private let manifest: ServiceManifest

  public init(store: SettingsStore, manifest: ServiceManifest, secretKeys: Set<String>) {
    self.store = store
    self.manifest = manifest
    self.scope = SettingsScope(
      owner: manifest.id,
      entitlements: manifest.entitlements,
      secretKeys: secretKeys,
      isBuiltIn: manifest.isBuiltIn
    )
  }

  // MARK: - This service's own fields

  /// A field from this service's own namespace. No entitlement needed, and none possible to
  /// forget: ownership is the key's prefix, so a service cannot reach another's field here
  /// even by naming it.
  public func own(_ field: String) async -> String {
    await store.string(forKey: manifest.storageKey(for: field)) ?? ""
  }

  public func ownFlag(_ field: String) async -> Bool {
    await own(field) == "true"
  }

  public func setOwn(_ value: String, field: String) async throws {
    let isSecret = manifest.fields.first { $0.key == field }?.isSecret ?? false
    try await store.set(value, forKey: manifest.storageKey(for: field), isSecret: isSecret)
  }

  // MARK: - Someone else's settings

  /// A core setting this service declared an entitlement for.
  ///
  /// Throws when it did not. The throw is the point — a service reading something it never
  /// declared is a bug in the manifest, and finding it at the first read is far cheaper than
  /// finding it when a user asks why a change had no effect.
  public func get<Value: SettingValue>(_ setting: Setting<Value>) async throws -> Value {
    try scope.checkRead(setting.key)
    return await store.get(setting)
  }

  /// The same, for a caller that would rather have the default than an error.
  ///
  /// Deliberately explicit at the call site: `try?` hides which of the two things happened,
  /// so the name says that a refusal yields the declared default.
  public func getOrDefault<Value: SettingValue>(_ setting: Setting<Value>) async -> Value {
    (try? await get(setting)) ?? setting.defaultValue
  }

  public func set<Value: SettingValue>(_ setting: Setting<Value>, to value: Value) async throws {
    try scope.checkWrite(setting.key)
    try await store.set(setting, to: value)
  }

  /// Whether a read would be allowed, for a caller deciding what to offer rather than
  /// what to do.
  public func canRead(_ key: String) -> Bool { scope.canRead(key) }

  /// The underlying store, for the composition root only.
  ///
  /// Present because a handful of built-ins legitimately need the whole store — the settings
  /// SCREEN renders everything, and the legacy import writes everything. Named so that
  /// reaching for it in a service is visibly a decision rather than an accident.
  public var unscopedForCompositionRoot: SettingsStore { store }
}
