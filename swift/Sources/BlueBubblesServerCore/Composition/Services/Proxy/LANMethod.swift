//  LANMethod
//  Local network: no tunnel, this Mac's own address.

import BBBuiltIns
import BBProxy
import BBServiceKit
import BBSystem

enum LANMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.lan }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    let port = await host.forwardedPort()
    // A chosen address wins; empty falls back to the automatic pick. Resolved at CONNECT
    // time rather than captured, so a machine whose address changed while idle republishes
    // the new one rather than a stale value.
    let chosen = await host.own("address").trimmingCharacters(in: .whitespaces)
    return LANProxy(
      port: port,
      addressResolver: {
        guard !chosen.isEmpty else { return SystemInfo.primaryIPv4() }
        // Only if this Mac still HAS it — otherwise a pinned address that has since
        // moved gets published to every client as the way to reach a server that is
        // not there.
        let available = SystemInfo.localAddresses(.ipv4)
        return available.contains(chosen) ? chosen : SystemInfo.primaryIPv4()
      }
    )
  }
}
