//  NetworkAddressChoices
//  Which addresses may be listened on, and which may be published.
//
//  A plain type rather than static members on the picker view, for the same reason
//  `AlertActionRouting` is: touching a SwiftUI `View` type from a test process traps, so
//  logic parked on a view is logic that cannot be tested. And this IS logic — the two lists
//  differ in a way that matters, and the difference is not obvious from either call site.
//
//  See `.claude/docs/architecture.md`.

import BBSystem

enum NetworkAddressChoices {

  struct Choice: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }
  }

  /// What the server may bind to.
  ///
  /// `0.0.0.0` and `127.0.0.1` are not interface addresses and never come out of
  /// `getifaddrs`, so they are added explicitly — without them the picker cannot express
  /// "listen everywhere", which is the default and the only thing the current server does.
  static func bind() -> [Choice] {
    [
      Choice(value: "0.0.0.0", label: "All interfaces (default)"),
      // Second because it is the right answer for every tunnel user, which is most of
      // them: the tunnel runs on this Mac and connects locally, so binding wider
      // exposes the API to the whole LAN for no benefit.
      Choice(value: "127.0.0.1", label: "Loopback only — for tunnels"),
    ] + interfaces()
  }

  /// What may be published as the LAN address.
  ///
  /// Neither wildcard belongs here, and that is the whole reason these are two lists.
  /// This value is handed to a CLIENT as the address to dial: `0.0.0.0` is not an address,
  /// and `127.0.0.1` is the client's own machine. Publishing either sends every device
  /// somewhere it cannot reach the server, which presents as "it worked at my desk".
  static func publishable() -> [Choice] {
    [Choice(value: "", label: "Automatic")] + interfaces()
  }

  private static func interfaces() -> [Choice] {
    SystemInfo.interfaces(.ipv4).map { interface in
      Choice(
        value: interface.address,
        label: "\(interface.address) — \(friendlyName(interface.name))"
      )
    }
  }

  /// The live choices, plus the current value when it is not among them.
  ///
  /// Without this a saved address whose interface has gone away would not appear in its own
  /// picker, so SwiftUI renders an empty selection and the first interaction silently
  /// rewrites the setting. Showing it as unavailable keeps the control honest about what is
  /// actually stored.
  static func including(selection: String, in choices: [Choice]) -> [Choice] {
    guard !choices.contains(where: { $0.value == selection }) else { return choices }
    return choices + [Choice(value: selection, label: "\(selection) — not available")]
  }

  /// Turns a BSD interface name into something a user can act on.
  ///
  /// This is the point of the whole control. Between `192.168.1.42` and `10.211.55.2` a
  /// user cannot tell which is their network; between "Wi-Fi or Ethernet" and "bridge or
  /// virtual machine" they can. Unrecognised names are shown raw rather than guessed at.
  static func friendlyName(_ interface: String) -> String {
    switch interface {
    case "en0", "en1": "\(interface) — Wi-Fi or Ethernet"
    case let name where name.hasPrefix("bridge"): "\(name) — bridge or virtual machine"
    case let name where name.hasPrefix("utun") || name.hasPrefix("ipsec"): "\(name) — VPN"
    case let name where name.hasPrefix("awdl") || name.hasPrefix("llw"):
      "\(name) — AirDrop, not routable"
    case let name where name.hasPrefix("anpi"): "\(name) — internal"
    default: interface
    }
  }
}
