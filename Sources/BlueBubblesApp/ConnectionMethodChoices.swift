//  ConnectionMethodChoices
//  The connection methods a user can pick from.
//
//  Built from the INSTALLED services in the exclusive `reverse-proxy` category rather than
//  from an enum. That is the difference that matters: a third-party tunnel appears here by
//  existing, without this file or any enum changing. It is also why the label and summary come
//  from the manifest; whoever wrote the service is the one who can describe it.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import BBBuiltIns
import BBInterfaces
import BBServiceKit
import BlueBubblesServerCore

enum ConnectionMethodChoices {

  /// The method to suggest to someone who has no reason to prefer another.
  ///
  /// Tailscale: a free account, a real certificate, an address that never changes, and a
  /// tailnet-only default that exposes nothing to the internet unless Funnel is chosen.
  /// A product decision, so it lives here in the app rather than on a manifest: a plugin
  /// declaring itself recommended is not something to build a field for.
  static let recommended = BuiltInManifests.ID.proxyTailscale

  static func isRecommended(_ manifest: ServiceManifest) -> Bool {
    manifest.id == recommended
  }

  /// The name, marked where it is the recommendation. For the places that show a bare
  /// label (a picker, a card title) and cannot carry a tag beside it.
  static func label(for manifest: ServiceManifest) -> String {
    isRecommended(manifest) ? "\(manifest.name) (Recommended)" : manifest.name
  }

  /// One entry per installed connection method: the recommendation first, then the ones
  /// needing no account, then the rest: the order someone setting up for the first time
  /// wants to read them in.
  static func available() -> [NetworkAddressChoices.Choice] {
    IntegrationCatalog.connectionMethods
      .sorted { lhs, rhs in
        let cost = { (manifest: ServiceManifest) in
          if isRecommended(manifest) { return -1 }
          return manifest.entitlements.contains(.spawnProcess) ? 1 : 0
        }
        if cost(lhs) != cost(rhs) { return cost(lhs) < cost(rhs) }
        return lhs.name < rhs.name
      }
      .map { manifest in
        NetworkAddressChoices.Choice(
          value: manifest.id.rawValue,
          label: label(for: manifest)
        )
      }
  }
}
