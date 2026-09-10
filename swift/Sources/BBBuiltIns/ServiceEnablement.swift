//  ServiceEnablement
//  Which services the user has switched off.
//
//  `disabled_services` is a comma-separated list of service identifiers, written by the
//  Integrations screen and consulted by the registry before it starts anything, so
//  switching Webhooks off actually stops the endpoints receiving events rather than only
//  changing the "enabled" tag beside the switch.
//
//  Parsing lives here rather than inline in the composition root because it is read from two
//  processes (the server applies it, the app renders it) and two spellings of "is this in
//  the list" is exactly how the app and the server end up disagreeing about what is running.
//
//  See `docs/EVENTS.md`.

import BBServiceKit
import BBSettings
import Foundation

public enum ServiceEnablement {

  /// The identifiers in a stored `disabled_services` value.
  ///
  /// Whitespace-tolerant and empty-tolerant: this value is reachable from the settings API
  /// and the CLI, so it arrives hand-typed as often as not.
  public static func disabledIdentifiers(in raw: String) -> Set<String> {
    Set(
      raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    )
  }

  /// The stored form of a disabled set: the inverse of `disabledIdentifiers(in:)`, kept
  /// beside it so the app writes exactly what the server parses.
  public static func serialized(_ disabled: Set<String>) -> String {
    disabled.sorted().joined(separator: ",")
  }

  /// Whether a service may run, given what the user has switched off.
  ///
  /// A core service is always enabled no matter what the list says; see
  /// `BuiltInManifests.alwaysOn`. Refusing here rather than trusting the writer means a
  /// hand-edited setting cannot take the server off the network.
  public static func isEnabled(_ id: ServiceIdentifier, disabled: Set<String>) -> Bool {
    guard !BuiltInManifests.alwaysOn.contains(id) else {
      return true
    }
    return !disabled.contains(id.rawValue)
  }

  public static func isEnabled(_ id: ServiceIdentifier, settings: SettingsStore) async -> Bool {
    let raw = await settings.string(forKey: Settings.disabledServicesKey) ?? ""
    return isEnabled(id, disabled: disabledIdentifiers(in: raw))
  }
}
