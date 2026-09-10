//  ScopedSettings
//  A service's settings store, narrowed to what its manifest declares.
//
//  The manifest says what a service may touch; this is what makes saying it matter. Handed to
//  a service at construction, it answers reads and writes that are permitted and THROWS on the
//  ones that are not, never returning nil, because a nil is indistinguishable from "unset"
//  and would put the caller straight back into the silent-inertness failure this whole model
//  exists to end.
//
//  **Every service is checked, built-in or not.** There is no trusted tier. A built-in that
//  reads a setting it never declared makes its permissions list a description of a different
//  program, and that list is the only thing a person has to go on when deciding whether to
//  trust a service at all.
//
//  Two honest limits, stated here rather than discovered later:
//
//    - **A secret is never readable, by anyone.** `checkRead` refuses it before it considers
//      entitlements at all, and `ManifestValidator` refuses a manifest that names one. A
//      service that needs a credential checked asks the host to check it.
//    - **This is a declaration that is checked, not a sandbox.** In-process code can open
//      `app.db` directly, so for the services compiled into this binary the enforcement
//      keeps the manifest HONEST rather than containing it. It becomes a real boundary for
//      out-of-process plugins, where the host answers each request over RPC and can decline,
//      which is exactly why the built-ins have to be correct now: they are the worked
//      examples a plugin author will copy, and the rules they exercise are the rules that
//      will be load-bearing when a third party runs.
//
//  Here rather than in BBServiceKit because that module deliberately cannot see BBSettings;
//  this is where a manifest and the settings store meet.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import BBServiceKit
import BBSettings
import Foundation
import Logging

public struct ScopedSettings: Sendable {

  private let store: SettingsStore
  private let scope: SettingsScope
  private let manifest: ServiceManifest
  /// Carried rather than passed per call: a refusal is reported against the SERVICE, and
  /// the scope is the only thing that knows which one without being told.
  private let logger: Logger

  public init(
    store: SettingsStore,
    manifest: ServiceManifest,
    secretKeys: Set<String>,
    logger: Logger = Logger(label: "bluebubbles.settings.scope")
  ) {
    self.store = store
    self.manifest = manifest
    self.logger = logger
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
  /// Throws when it did not. The throw is the point: a service reading something it never
  /// declared is a bug in the manifest, and finding it at the first read is far cheaper than
  /// finding it when a user asks why a change had no effect.
  public func get<Value: SettingValue>(_ setting: Setting<Value>) async throws -> Value {
    try scope.checkRead(setting.key)
    return await store.get(setting)
  }

  /// For a caller that cannot throw: a `health` getter, or a closure the framework hands
  /// no error channel.
  ///
  /// A refusal here is a MANIFEST BUG, never a normal outcome: the service is reading
  /// something it did not declare. So it yields the declared default and says so at error
  /// level, rather than returning it silently: a refused read that quietly becomes a
  /// default is indistinguishable from a setting nobody configured, which is the
  /// silent-inertness failure this whole model exists to end.
  public func valueOrDefault<Value: SettingValue>(_ setting: Setting<Value>) async -> Value {
    do {
      return try await get(setting)
    } catch {
      logger.error(
        "A service read a setting it never declared; using the default",
        metadata: [
          "service": .string(manifest.id.rawValue),
          "setting": .string(setting.key),
          "default": .string(String(describing: setting.defaultValue)),
        ])
      return setting.defaultValue
    }
  }

  public func set<Value: SettingValue>(_ setting: Setting<Value>, to value: Value) async throws {
    try scope.checkWrite(setting.key)
    try await store.set(setting, to: value)
  }

  /// The write counterpart to `valueOrDefault`, for a closure with no error channel.
  ///
  /// Reports rather than swallows, for the same reason: a refused write that returns
  /// quietly leaves the caller believing it persisted something.
  @discardableResult
  public func trySet<Value: SettingValue>(
    _ setting: Setting<Value>, to value: Value
  ) async -> Bool {
    do {
      try await set(setting, to: value)
      return true
    } catch {
      logger.error(
        "A service wrote a setting it never declared; the value was not stored",
        metadata: [
          "service": .string(manifest.id.rawValue),
          "setting": .string(setting.key),
        ])
      return false
    }
  }

  /// Whether a read would be allowed, for a caller deciding what to offer rather than
  /// what to do.
  public func canRead(_ key: String) -> Bool { scope.canRead(key) }

  /// The underlying store, for the composition root only.
  ///
  /// Present because a handful of built-ins legitimately need the whole store: the settings
  /// SCREEN renders everything, and the legacy import writes everything. Named so that
  /// reaching for it in a service is visibly a decision rather than an accident.
  public var unscopedForCompositionRoot: SettingsStore { store }
}
