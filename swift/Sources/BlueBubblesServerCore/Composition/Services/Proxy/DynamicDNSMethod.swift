//  DynamicDNSMethod
//  "Custom URL": publishes an address the user maintains.

import BBBuiltIns
import BBProxy
import BBServiceKit

enum DynamicDNSMethod: ProxyMethod {
  static var manifest: ServiceManifest { BuiltInManifests.dynamicDNS }

  static func makeProvider(_ host: ProxyHost) async -> (any ProxyProviding)? {
    // The one provider whose address is INPUT rather than output: the user maintains the
    // DNS record and this only republishes what they typed.
    let address = await host.own("address")
    guard !address.isEmpty else { return nil }
    return DynamicDNSProxy(address: address)
  }
}
