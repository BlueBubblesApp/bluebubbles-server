//  ServiceEnablement
//  Which services the user has switched off.
//
//  `disabled_services` is a comma-separated list of service identifiers, written by the
//  Integrations screen. It had no reader: the registry started everything it was given, so
//  switching Webhooks off left every endpoint still receiving events, and the switch's only
//  visible effect was the "enabled" tag beside it. The setting was, in effect, a note the UI
//  wrote to itself.
//
//  Parsing lives here rather than inline in the composition root because it is read from two
//  processes — the server applies it, the app renders it — and two spellings of "is this in
//  the list" is exactly how the app and the server end up disagreeing about what is running.
//
//  See `docs/EVENTS.md`.

import BBHandlers
import BBInterfaces
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

  /// Whether a service may run, given what the user has switched off.
  ///
  /// A core service is always enabled no matter what the list says — see
  /// `BuiltInManifests.alwaysOn`. Refusing here rather than trusting the writer means a
  /// hand-edited setting cannot take the server off the network.
  public static func isEnabled(_ id: ServiceID, disabled: Set<String>) -> Bool {
    guard !BuiltInManifests.alwaysOn.contains(ServiceIdentifier(id.rawValue)) else {
      return true
    }
    return !disabled.contains(id.rawValue)
  }

  static func isEnabled(_ id: ServiceID, settings: SettingsStore) async -> Bool {
    let raw = await settings.string(forKey: Settings.disabledServicesKey) ?? ""
    return isEnabled(id, disabled: disabledIdentifiers(in: raw))
  }
}
