//  Setting
//  Typed setting descriptors: a key, a value type, a default, and how a change is applied.
//
//  See `.claude/docs/database.md` — Typed, secure, reactive settings.

import BBCore
import Foundation

/// A value that can round-trip through the settings store with its type preserved.
///
/// The stored representation carries an explicit type tag, so nothing is ever inferred. That
/// is what removes the current `"1"`/`"0"` → Bool collision, makes `Date` readable rather
/// than write-only, and retires the `start_delay: "0.0"` string hack whose own comment says
/// it exists to dodge boolean parsing.
public protocol SettingValue: Codable, Sendable, Equatable {
  static var typeTag: String { get }
}

extension Bool: SettingValue { public static var typeTag: String { "bool" } }
extension Int: SettingValue { public static var typeTag: String { "int" } }
extension Double: SettingValue { public static var typeTag: String { "double" } }
extension String: SettingValue { public static var typeTag: String { "string" } }
extension Date: SettingValue { public static var typeTag: String { "date" } }

/// How a setting should be presented, declared alongside the setting itself.
///
/// Carrying this here is what lets the SwiftUI settings screen be generated from the
/// registry, collapsing ~35 near-identical `*Field.tsx` components into one row view.
public struct SettingPresentation: Sendable {
  public struct Option: Sendable, Equatable {
    public let value: String
    public let label: String
    public init(value: String, label: String) {
      self.value = value
      self.label = label
    }
  }

  public enum Control: Sendable {
    case toggle
    case textField
    case secureField
    case number(range: ClosedRange<Int>?)
    case picker(options: [Option])
    case path
    /// Shown but not editable — a value this server DERIVES and the user reads.
    ///
    /// Distinct from `isInternal`, which hides a setting entirely. `server_address` has to
    /// be visible (it is the thing a user copies into a client) and must not be typed into:
    /// it is written by whichever connection method is running, so an edit is overwritten
    /// on the next publish, and in the meantime every keystroke is announced to Firebase as
    /// the server's new address.
    case readOnly
    /// Rendered by a bespoke view; not auto-generated.
    case custom
  }

  public let label: String
  public let help: String?
  public let section: String
  public let control: Control
  /// Hidden from the generated UI — internal bookkeeping such as `last_fcm_restart`.
  public let isInternal: Bool

  /// Whether the UI should offer to generate a value.
  ///
  /// Opt-in, because "secret" does not imply "ours to invent". The server password is a
  /// shared secret this app defines, so generating a strong one is the best thing a user
  /// can do with the field. An ntfy access token is issued by ntfy: a generated one would
  /// be a valid-looking string that authenticates nothing.
  public let canGenerate: Bool

  public init(
    label: String,
    help: String? = nil,
    section: String,
    control: Control,
    isInternal: Bool = false,
    canGenerate: Bool = false
  ) {
    self.label = label
    self.help = help
    self.section = section
    self.control = control
    self.isInternal = isInternal
    self.canGenerate = canGenerate
  }
}

/// When a change to a setting takes effect.
///
/// Declared on the setting rather than listed by the propagation layer, so the list of
/// "restart to apply" keys is derived from the declarations and cannot drift from them.
public enum SettingApplication: Sendable, Equatable {
  /// Read live, or by a service that restarts itself when the value changes.
  case live
  /// Read once while the server is assembled — it decides which routes mount, which codec
  /// the socket negotiates, how chat.db is opened. A change needs a full restart, and the
  /// propagation layer says so rather than pretending to apply it.
  case composition
}

/// A single setting, declared once.
///
/// `key` is the STORAGE name and must not change. Renaming one orphans the row a user's
/// value is already in, so their setting silently reverts to its default; it also breaks the
/// name in their config file and in `--set`, and breaks the mapping `LegacyConfigMigration`
/// uses to read the Electron server's `config.db`.
///
/// It is not currently a wire name. Nothing serves the settings map to a client — the socket
/// `get-server-config` command these keys were named for has no dispatch path here, by
/// design. Renaming one is still a breaking change; the breakage is local rather than remote.
public struct Setting<Value: SettingValue>: Sendable {
  public let key: String
  public let defaultValue: Value

  /// Secrets live in the Keychain with an access control bound to the app's code
  /// signature; the database row holds only a reference. Anything true here is also
  /// automatically wrapped as `DiagnosticValue.secret` wherever it appears in diagnostics.
  public let isSecret: Bool

  public let validate: (@Sendable (Value) throws -> Void)?
  public let presentation: SettingPresentation?
  public let application: SettingApplication

  public init(
    _ key: String,
    default defaultValue: Value,
    isSecret: Bool = false,
    application: SettingApplication = .live,
    validate: (@Sendable (Value) throws -> Void)? = nil,
    presentation: SettingPresentation? = nil
  ) {
    self.key = key
    self.defaultValue = defaultValue
    self.isSecret = isSecret
    self.application = application
    self.validate = validate
    self.presentation = presentation
  }
}

/// Where a resolved value came from. Layers resolve in ascending order, so a CLI argument
/// beats the YAML file, which beats the persisted store, which beats the declared default.
///
/// This replaces writing CLI values *into* the database, and with it the `--persist-config`
/// flag that exists only to undo that.
public enum SettingSource: Int, Sendable, Comparable, CaseIterable {
  case declaredDefault = 0
  case persistedStore = 1
  case configFile = 2
  case commandLine = 3

  public static func < (lhs: SettingSource, rhs: SettingSource) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public enum SettingsError: BBError {
  case validationFailed(key: String, reason: String)
  case keychainUnavailable(key: String, status: Int32)
  case typeMismatch(key: String, expected: String, found: String)

  public var code: String {
    switch self {
    case .validationFailed: "settings.validation_failed"
    case .keychainUnavailable: "settings.keychain_unavailable"
    case .typeMismatch: "settings.type_mismatch"
    }
  }

  public var domain: String { "Settings" }

  public var title: String {
    switch self {
    case .validationFailed: "Invalid setting value"
    case .keychainUnavailable: "Could not reach the Keychain"
    case .typeMismatch: "Stored setting has the wrong type"
    }
  }

  public var body: String {
    switch self {
    case .validationFailed(let key, let reason):
      // The reason leads, because it is the part that tells someone what to do. The key is
      // the raw storage name (`socket_port`), so it is only worth showing when the message
      // has to identify WHICH setting — and at a row that already carries its own label,
      // it does not.
      "\(reason.prefix(1).uppercased())\(reason.dropFirst()) (\(key))"
    case .keychainUnavailable(let key, _):
      "\(key) is stored in the Keychain, which could not be read. "
        + "Secrets such as your server password may be unavailable until this is resolved."
    case .typeMismatch(let key, let expected, let found):
      "\(key) was stored as \(found) but is declared as \(expected). The default will be used."
    }
  }

  /// Only the Keychain failure is worth interrupting someone over — the other two are
  /// developer-facing and get logged.
  public var isUserFacing: Bool {
    if case .keychainUnavailable = self { return true }
    return false
  }

  public var context: [String: DiagnosticValue] {
    switch self {
    case .validationFailed(let key, let reason):
      ["key": .string(key), "reason": .string(reason)]
    case .keychainUnavailable(let key, let status):
      ["key": .string(key), "os_status": .int(Int(status))]
    case .typeMismatch(let key, let expected, let found):
      ["key": .string(key), "expected": .string(expected), "found": .string(found)]
    }
  }
}
