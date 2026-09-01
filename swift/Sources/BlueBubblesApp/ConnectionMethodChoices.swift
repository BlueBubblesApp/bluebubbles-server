//  ConnectionMethodChoices
//  The connection methods a user can pick from.
//
//  Built from the INSTALLED services in the exclusive `reverse-proxy` category rather than
//  from an enum. That is the difference that matters: a third-party tunnel appears here by
//  existing, without this file or any enum changing. It is also why the label and summary come
//  from the manifest — whoever wrote the service is the one who can describe it.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import BBHandlers
import BBInterfaces
import BBServiceKit
import BlueBubblesServerCore

enum ConnectionMethodChoices {

  /// One entry per installed connection method, ordered so the ones needing no account come
  /// first — which is the order someone setting up for the first time wants to read them in.
  static func available() -> [NetworkAddressChoices.Choice] {
    BuiltInManifests.all
      .filter { $0.category == .reverseProxy }
      .sorted { lhs, rhs in
        let cost = { (manifest: ServiceManifest) in
          manifest.entitlements.contains(.spawnProcess) ? 1 : 0
        }
        if cost(lhs) != cost(rhs) { return cost(lhs) < cost(rhs) }
        return lhs.name < rhs.name
      }
      .map { manifest in
        NetworkAddressChoices.Choice(
          value: manifest.id.rawValue,
          label: manifest.name
        )
      }
  }
}
