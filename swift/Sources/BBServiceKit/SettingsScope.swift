//  SettingsScope
//  What one service is actually allowed to read and write.
//
//  The manifest declares; this enforces. Without it the declaration is documentation, and
//  documentation does not stop a plugin from reading the server password — it only records
//  that it was not supposed to.
//
//  Three rules, in order:
//
//    1. A service may always read and write its OWN namespace (`<id>.*`). No entitlement
//       needed; that is what owning a namespace means.
//    2. Anything outside it requires a matching `readSettings` / `writeSettings` entitlement,
//       naming the exact key. No wildcards — "read everything under ngrok_" is not a thing a
//       user can meaningfully consent to.
//    3. Secrets are never readable, entitlement or not. `ManifestValidator` refuses a manifest
//       that asks, and this refuses again at the point of access, because the two run at
//       different times and a manifest can be edited after it was validated.
//
//  Denial THROWS rather than returning nil. That is deliberate and load-bearing: a nil would
//  be indistinguishable from "unset", which is exactly the silent-inertness failure this
//  project keeps finding — a setting that reads as absent, so the code takes its default and
//  nobody learns the access was refused.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import BBCore
import Foundation

public enum SettingsAccessError: BBError, Equatable, CustomStringConvertible {
  case notEntitledToRead(service: ServiceIdentifier, key: String)
  case notEntitledToWrite(service: ServiceIdentifier, key: String)
  case secretsAreNeverReadable(service: ServiceIdentifier, key: String)

  public var description: String {
    switch self {
    case .notEntitledToRead(let service, let key):
      "\(service) tried to read '\(key)' without declaring it. Add "
        + "`.readSettings(keys: [\"\(key)\"])` to its manifest."
    case .notEntitledToWrite(let service, let key):
      "\(service) tried to write '\(key)' without declaring it. Add "
        + "`.writeSettings(keys: [\"\(key)\"])` to its manifest."
    case .secretsAreNeverReadable(let service, let key):
      "\(service) tried to read the secret '\(key)'. Secrets are never handed to a "
        + "service — ask the host to perform the operation instead."
    }
  }
}

/// One service's view of the settings store.
public struct SettingsScope: Sendable {

  public let owner: ServiceIdentifier
  private let readable: Set<String>
  private let writable: Set<String>
  private let secretKeys: Set<String>
  /// Built-in services are trusted with the core configuration.
  ///
  /// Not a loophole so much as an honest statement of where the boundary is: built-ins are
  /// compiled into this binary and can read the database file directly, so pretending to
  /// contain them would be theatre. The boundary is real for out-of-process plugins, which
  /// is where § 12 puts third parties.
  private let isBuiltIn: Bool

  public init(
    owner: ServiceIdentifier,
    entitlements: [Entitlement],
    secretKeys: Set<String>,
    isBuiltIn: Bool
  ) {
    self.owner = owner
    self.secretKeys = secretKeys
    self.isBuiltIn = isBuiltIn

    var readable: Set<String> = []
    var writable: Set<String> = []
    for entitlement in entitlements {
      switch entitlement {
      case .readSettings(let keys): readable.formUnion(keys)
      case .writeSettings(let keys): writable.formUnion(keys)
      default: break
      }
    }
    // Writing implies reading. A service that may change a value but cannot read it back
    // can only ever clobber it, never adjust it.
    self.readable = readable.union(writable)
    self.writable = writable
  }

  /// A scope for a built-in that has declared nothing — the core services, which predate
  /// manifests and are trusted with everything.
  public static func unrestricted(owner: ServiceIdentifier) -> SettingsScope {
    SettingsScope(owner: owner, entitlements: [], secretKeys: [], isBuiltIn: true)
  }

  public func ownsKey(_ key: String) -> Bool {
    key.hasPrefix(owner.settingsNamespace)
  }

  public func canRead(_ key: String) -> Bool {
    (try? checkRead(key)) != nil
  }

  public func canWrite(_ key: String) -> Bool {
    (try? checkWrite(key)) != nil
  }

  /// Throws unless this service may read `key`.
  public func checkRead(_ key: String) throws {
    if ownsKey(key) { return }

    // Checked before the entitlement, so a built-in cannot read a secret either. The
    // trust extended to built-ins is about the CORE CONFIGURATION, not about credentials:
    // a service that needs the password gets `.authenticateRequests`.
    if secretKeys.contains(key) {
      throw SettingsAccessError.secretsAreNeverReadable(service: owner, key: key)
    }
    if isBuiltIn || readable.contains(key) { return }
    throw SettingsAccessError.notEntitledToRead(service: owner, key: key)
  }

  /// Throws unless this service may write `key`.
  public func checkWrite(_ key: String) throws {
    if ownsKey(key) { return }
    if isBuiltIn || writable.contains(key) { return }
    throw SettingsAccessError.notEntitledToWrite(service: owner, key: key)
  }

  /// Every foreign key this scope permits, for showing a user what a service can see.
  public var declaredForeignKeys: (readable: [String], writable: [String]) {
    (readable.sorted(), writable.sorted())
  }
}

extension SettingsAccessError {
  public var code: String {
    switch self {
    case .notEntitledToRead: "settings.not_entitled_to_read"
    case .notEntitledToWrite: "settings.not_entitled_to_write"
    case .secretsAreNeverReadable: "settings.secret_not_readable"
    }
  }

  public var domain: String { "Services" }

  public var title: String { "A service asked for a setting it may not touch" }

  public var body: String { description }
}
