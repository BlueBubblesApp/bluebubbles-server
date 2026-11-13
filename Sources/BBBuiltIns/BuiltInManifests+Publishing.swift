//  BuiltInManifests+Publishing
//  The connection methods with no process and no network egress: Local Network and Custom
//  URL, which only publish an address clients already reach.
//
//  Its own file so the comparison the permission list is meant to make possible is visible in
//  the tree as well: next to the tunnels (`BuiltInManifests+Tunnels.swift`) these declare
//  almost nothing. `lan` is computed because its options are this machine's interfaces.

import BBServiceKit
import BBSettings
import BBSystem

extension BuiltInManifests {

  /// Computed, because its options are THIS machine's network interfaces.
  ///
  /// A `static let` cannot know them: a Mac with a VPN, a virtual machine, or both Wi-Fi and
  /// Ethernet has several LAN addresses, and which one a client can actually reach is a fact
  /// about the machine rather than about the service. Re-enumerated on each access so
  /// plugging in a cable adds the option without a restart.
  ///
  /// Safe to compute despite `__version` bookkeeping: `ServiceMigration` keys off
  /// `manifest.version`, which is fixed here, not off deep equality of the manifest.
  public static var lan: ServiceManifest {
    ServiceManifest(
      id: ID.proxyLAN,
      name: "Local Network",
      summary: "Reach this server only from your own network.",
      details: """
        No tunnel at all: clients connect straight to this Mac's address. The simplest and \
        fastest option, and it works only while the client is on the same network.
        """,
      category: .reverseProxy,
      symbol: "wifi",
      dependencies: [ID.http],
      // No process, no network egress. Worth noticing that this one asks for almost nothing,
      // which is exactly the comparison a permission list is meant to make possible.
      entitlements: publishingEntitlements,
      settings: [
        .paragraph(
          "Clients connect straight to this Mac. Choose which of its addresses to "
            + "publish; most Macs have one, but a VPN or a virtual machine adds more."
        ),
        .field(
          FieldDescriptor(
            key: "address",
            label: "Address",
            help: "Automatic follows this Mac's primary interface. Pick a specific "
              + "address if clients can only reach one of them. If a pinned address "
              + "disappears, the automatic one is published instead.",
            kind: .select(options: lanAddressOptions())
          )),
      ]
    )
  }

  /// Automatic, then one option per IPv4 interface.
  ///
  /// The automatic entry names the address it resolves to, because "Automatic" on
  /// its own does not answer the question the user opened this field to ask: which address
  /// their clients are going to be handed.
  static func lanAddressOptions() -> [FieldOption] {
    let automatic = SystemInfo.primaryIPv4()
    var options = [
      FieldOption(
        value: "",
        label: automatic.map { "Automatic (\($0))" } ?? "Automatic"
      )
    ]
    // Interface name alongside the address: on a Mac with a VPN up, two private addresses
    // look equally plausible and `utun3` versus `en0` is the thing that distinguishes them.
    for interface in SystemInfo.interfaces(.ipv4) {
      options.append(
        FieldOption(
          value: interface.address,
          label: "\(interface.address) (\(interface.name))"
        ))
    }
    return options
  }

  /// Named "Custom URL" and identified `…proxy.dynamic-dns`.
  ///
  /// The NAME changed and the ID did not, deliberately: the identifier is the key every
  /// stored setting for this method hangs off (`app.bluebubbles.proxy.dynamic-dns.address`)
  /// and the value `connection_method` holds, so renaming it would orphan the address of
  /// anyone already using it and silently reset them to no connection method at all.
  ///
  /// "Dynamic DNS" described one way of keeping the record current rather than what this
  /// option does, which is publish a URL you supply. Dynamic DNS is a way to make that URL
  /// keep working; it is not a requirement, and a static record or a reverse proxy you run
  /// yourself fits here just as well.
  public static let dynamicDNS = ServiceManifest(
    id: ID.proxyDynamicDNS,
    name: "Custom URL",
    summary: "Publish an address you manage yourself (i.e. Dynamic DNS).",
    details: """
      For people running their own DNS, port forwarding or reverse proxy. This server \
      publishes the URL you enter and does nothing else: keeping it pointing at your \
      network is up to you, whether that is a static record or a dynamic DNS client.
      """,
    category: .reverseProxy,
    symbol: "globe",
    dependencies: [ID.http],
    entitlements: publishingEntitlements,
    settings: [
      .field(
        FieldDescriptor(
          key: "address",
          label: "Address",
          help: "The full URL clients should use, including the port.",
          kind: .url,
          isConfidential: true,
          isRequired: true
        ))
    ]
  )
}
