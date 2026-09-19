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
    let address = await host.own("address").trimmingCharacters(in: .whitespaces)
    guard !address.isEmpty else {
      // Said, rather than left to `ProxyService`, which would otherwise report a missing
      // binary for a method that has none.
      await host.complain(
        title: "Dynamic DNS has no address",
        body: "Enter the hostname your dynamic DNS provider gave you on the Dynamic DNS "
          + "page; without it there is nothing to publish to clients.",
        key: "address-missing"
      )
      return nil
    }
    return DynamicDNSProxy(address: address)
  }
}
