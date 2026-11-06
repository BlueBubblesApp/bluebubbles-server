//  ExportedKeys
//  Every key an archive may carry: the declared settings, each service's own fields, and
//  the list of services switched off.
//
//  **A service's configuration is not in `Settings.all`.** Its fields are declared on its
//  manifest and stored under the service's namespace, and which services are switched off
//  is `disabled_services`, a key with no declaration at all. An export that walks only the
//  declarations carries the port and the CHOICE of connection method and leaves the method
//  itself behind: every token, hostname and switch on the ngrok, zrok, Cloudflare and
//  Tailscale pages. A restore onto a new Mac then comes up selecting a tunnel it has no way
//  to open, and nothing in the import says so.
//
//  **The manifests are handed in rather than looked up.** This module sits below the one
//  that knows which services exist, and the list is what decides which namespaced keys an
//  archive may write: a key under no manifest's namespace is refused on the way in, so a
//  hand-edited archive cannot plant one.
//
//  One list, asked by both directions, so the exporter cannot write a key the importer
//  would refuse, or route one to the other file.

import BBServiceKit
import BBSettings
import Foundation

struct ExportedKeys: Sendable {

  /// What declares a key, which decides how its value is read and written back.
  enum Origin: Sendable {
    /// A core setting, written back through its own declaration and so its own validator.
    case declared(AnySetting)
    /// A service's field, held to the field's own `validation` on the way back in.
    case field(FieldDescriptor)
    /// `disabled_services`, a comma-separated list that only the enablement code writes.
    case enablement
  }

  struct Entry: Sendable {
    let key: String
    let origin: Origin
    let route: SettingPortability.Route
  }

  let entries: [Entry]
  private let byKey: [String: Entry]

  init(services: [ServiceManifest]) {
    var entries = Settings.all.map { setting in
      Entry(
        key: setting.key, origin: .declared(setting),
        route: SettingPortability.route(
          setting.key, isSecret: setting.isSecret, isConfidential: setting.isConfidential))
    }
    for manifest in services {
      for field in manifest.fields {
        let key = manifest.storageKey(for: field.key)
        entries.append(
          Entry(
            key: key, origin: .field(field),
            route: SettingPortability.route(
              key, isSecret: field.isSecret, isConfidential: field.isConfidential)))
      }
    }
    entries.append(
      Entry(
        key: Settings.disabledServicesKey, origin: .enablement,
        route: SettingPortability.route(
          Settings.disabledServicesKey, isSecret: false, isConfidential: false)))
    self.entries = entries
    // First wins: a namespaced field cannot collide with a core key, because the namespace
    // is the service identifier, and two manifests sharing one are refused by
    // `ManifestValidator` before anything starts.
    byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
  }

  func entry(for key: String) -> Entry? { byKey[key] }
}
