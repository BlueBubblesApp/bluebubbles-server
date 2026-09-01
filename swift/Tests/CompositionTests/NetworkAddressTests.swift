//  NetworkAddressTests
//  Choosing what to listen on, and what to publish.
//
//  Two settings that look similar and are not interchangeable: `bind_address` is what the
//  server passes to `bind(2)`, and `lan_address` is what it hands a CLIENT as the address to
//  dial. Confusing them produces a server that either listens nowhere useful or advertises an
//  address nothing can reach, and both fail quietly.
//
//  Verified live before these were written: the default binds `0.0.0.0`; `127.0.0.1` binds
//  loopback only and LAN requests are refused; a real interface address binds and serves on
//  it; and an address this Mac does not have is refused with an alert naming what is
//  available rather than falling back to a wider bind.
//
//  See `.claude/docs/architecture.md`.

import BBServiceKit
import BBSettings
import BBSystem
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesApp
@testable import BlueBubblesServerCore

@Suite("Network address selection")
struct NetworkAddressTests {

  // MARK: - What may be bound

  @Test("Bind choices lead with all-interfaces and loopback")
  func bindChoicesIncludeTheWildcards() {
    // Neither is an interface address, so neither comes out of `getifaddrs` — they have to
    // be added explicitly or the picker cannot express "listen everywhere", which is the
    // default and the current server's only behaviour.
    let values = NetworkAddressChoices.bind().map(\.value)
    #expect(values.first == "0.0.0.0")
    #expect(values.contains("127.0.0.1"))
  }

  @Test("Publishable LAN choices exclude the wildcards")
  func lanChoicesExcludeWildcards() {
    // This value is given to a client as the address to dial. `0.0.0.0` is not an address
    // and `127.0.0.1` is the client's own machine — publishing either sends every device
    // somewhere it cannot reach the server, which presents as "it worked at my desk".
    let values = NetworkAddressChoices.publishable().map(\.value)
    #expect(!values.contains("0.0.0.0"))
    #expect(!values.contains("127.0.0.1"))
    // Empty is "automatic", which is the default and must remain selectable.
    #expect(values.contains(""))
  }

  @Test("A stored address that no longer exists still appears, marked unavailable")
  func missingSelectionIsStillShown() {
    // SwiftUI renders an empty selection when the bound value is not among the tags, and
    // the first interaction then silently rewrites the setting. Showing it as unavailable
    // keeps the control honest about what is actually stored.
    let labels = NetworkAddressChoices.including(
      selection: "10.99.99.99",
      in: [.init(value: "0.0.0.0", label: "All interfaces")]
    ).map(\.label)
    #expect(labels.contains { $0.contains("not available") })
  }

  // MARK: - Naming

  @Test("Interface names are translated into something a user can act on")
  func friendlyNames() {
    // The whole reason this control exists. Between `192.168.1.42` and `10.211.55.2` a
    // user cannot tell which is their network; between "Wi-Fi or Ethernet" and "bridge or
    // virtual machine" they can.
    #expect(NetworkAddressChoices.friendlyName("en0").contains("Wi-Fi"))
    #expect(NetworkAddressChoices.friendlyName("bridge100").contains("virtual machine"))
    #expect(NetworkAddressChoices.friendlyName("utun3").contains("VPN"))
    #expect(NetworkAddressChoices.friendlyName("awdl0").contains("not routable"))
    // Unknown names are shown raw rather than guessed at.
    #expect(NetworkAddressChoices.friendlyName("qux9") == "qux9")
  }

  // MARK: - Enumeration

  @Test("Enumerated interfaces are routable addresses with a name")
  func interfacesAreUsable() {
    for interface in SystemInfo.interfaces(.ipv4) {
      #expect(!interface.name.isEmpty)
      #expect(interface.address != "127.0.0.1", "loopback is not a LAN interface")
      #expect(!interface.address.hasPrefix("169.254"), "link-local is not routable")
    }
  }

  @Test("The primary address is one of the enumerated ones")
  func primaryIsReal() {
    // `primaryIPv4` prefers en0/en1 and falls back to the first. Either way it must be an
    // address this machine actually has, or the LAN URL points nowhere.
    guard let primary = SystemInfo.primaryIPv4() else { return }
    #expect(SystemInfo.localAddresses(.ipv4).contains(primary))
  }

  // MARK: - Settings

  @Test("Both settings are registered and default to the current behaviour")
  func settingsRegistered() {
    // Defaults matter: `0.0.0.0` is what the server has always bound, and an empty LAN
    // address means automatic. A different default would change behaviour for every
    // existing install on upgrade.
    #expect(Settings.allKeys.contains("bind_address"))
    #expect(Settings.bindAddress.defaultValue == "0.0.0.0")

    // The LAN address is no longer a core setting: it belongs to the LAN connection
    // method and is declared by its manifest, so it lives at
    // `app.bluebubbles.proxy.lan.address`. Asserted here so the move is deliberate rather
    // than a deletion someone has to notice.
    #expect(!Settings.allKeys.contains("lan_address"))
    #expect(BuiltInManifests.lan.fields.contains { $0.key == "address" })
    #expect(
      BuiltInManifests.lan.storageKey(for: "address")
        == "app.bluebubbles.proxy.lan.address")
  }
}
