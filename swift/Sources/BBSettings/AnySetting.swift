//  AnySetting
//  A type-erased setting, so the UI can enumerate what it must render.
//
//  `Setting<Value>` is generic, which is right for the call sites — `settings.get(Settings.port)`
//  returns an Int with no cast. But a generated settings screen has to walk a heterogeneous
//  list, and a generic type cannot go in an array.
//
//  This is what makes "declared once in BBSettings, rendered generically" true rather than
//  aspirational. Without it the SwiftUI screen would hand-list every setting, which is the
//  ~35 near-identical `*Field.tsx` components again with different syntax — and the same
//  failure mode, where adding a setting means remembering to add a row.
//
//  See `.claude/docs/architecture.md`.

import Foundation

/// A setting's value, in the shapes the controls actually produce.
///
/// `Date` is absent because every Date setting is internal bookkeeping — `last_fcm_restart`
/// and the like — with no presentation and therefore no row to render. `Double` is here
/// because `start_delay` is user-facing and is one.
public enum SettingBox: Sendable, Equatable {
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)

  public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
  public var stringValue: String? { if case .string(let value) = self { value } else { nil } }

  /// Accepts either numeric case, so a control that edits a whole number works against a
  /// `Double` setting without the caller knowing which it is.
  public var intValue: Int? {
    switch self {
    case .int(let value): value
    case .double(let value): Int(value)
    default: nil
    }
  }

  public var doubleValue: Double? {
    switch self {
    case .double(let value): value
    case .int(let value): Double(value)
    default: nil
    }
  }
}

/// One renderable setting.
public struct AnySetting: Sendable, Identifiable {

  public let key: String
  public let presentation: SettingPresentation
  public let isSecret: Bool
  /// Whether the setting declares a validator.
  ///
  /// Exposed so the invariant "only the server password is entropy-gated" can be asserted
  /// structurally. The ngrok, zrok and ntfy tokens are issued by those services and their
  /// shape is theirs to decide; applying a human-password rule to one would reject a valid
  /// credential with an error about predictability that makes no sense for it.
  public let hasValidator: Bool
  public var id: String { key }

  /// Reads the current value through the store, preserving the layered resolution — a
  /// value overridden on the command line reads back as the override, so the UI shows what
  /// is actually in effect rather than what is persisted.
  public let read: @Sendable (SettingsStore) async -> SettingBox

  /// Writes, validating first. Throws exactly what `SettingsStore.set` throws, so a
  /// rejected value surfaces its reason rather than a generic failure.
  public let write: @Sendable (SettingsStore, SettingBox) async throws -> Void

  /// Where the effective value came from, so the UI can say "set on the command line" for
  /// a row the user cannot usefully change.
  public let source: @Sendable (SettingsStore) async -> SettingSource

  init<Value: SettingValue>(
    _ setting: Setting<Value>,
    box: @escaping @Sendable (Value) -> SettingBox,
    unbox: @escaping @Sendable (SettingBox) -> Value?
  ) {
    // Only settings that declared a presentation are renderable. A setting without one
    // is internal by construction.
    self.key = setting.key
    self.presentation =
      setting.presentation
      ?? SettingPresentation(
        label: setting.key, section: "Other", control: .custom, isInternal: true
      )
    self.isSecret = setting.isSecret
    self.hasValidator = setting.validate != nil

    self.read = { store in box(await store.get(setting)) }
    self.write = { store, value in
      guard let typed = unbox(value) else {
        throw SettingsError.typeMismatch(
          key: setting.key, expected: Value.typeTag, found: String(describing: value)
        )
      }
      try await store.set(setting, to: typed)
    }
    self.source = { store in await store.resolve(setting).source }
  }
}

extension Setting where Value == Bool {
  public var erased: AnySetting { AnySetting(self, box: SettingBox.bool, unbox: \.boolValue) }
}

extension Setting where Value == Int {
  public var erased: AnySetting { AnySetting(self, box: SettingBox.int, unbox: \.intValue) }
}

extension Setting where Value == Double {
  public var erased: AnySetting { AnySetting(self, box: SettingBox.double, unbox: \.doubleValue) }
}

extension Setting where Value == String {
  public var erased: AnySetting { AnySetting(self, box: SettingBox.string, unbox: \.stringValue) }
}

/// A setting whose value is an enum with a String raw value — `auth_mode`, the codec picker.
///
/// Boxed as its raw value so the picker deals in strings and the store still round-trips the
/// real type.
extension Setting where Value: RawRepresentable, Value.RawValue == String, Value: SettingValue {
  public var erased: AnySetting {
    AnySetting(
      self,
      box: { .string($0.rawValue) },
      unbox: { $0.stringValue.flatMap(Value.init(rawValue:)) }
    )
  }
}
