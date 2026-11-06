//  TailscaleHandoff
//  What the Tailscale page says about a Tailscale somebody else already runs on this Mac,
//  and which address it offers to hand to Custom URL.
//
//  The Tailscale connection method runs a node of its own, so a person whose Mac is already
//  signed in to their tailnet signs in a second time and gets a second machine. Some of them
//  would rather run `tailscale serve` themselves; for them the right method is Custom URL,
//  and the useful thing to do is say so and fill the address in.
//
//  **An address is filled in only when there is exactly one.** Several mounts forwarding to
//  this server is a person's configuration we cannot read intent from, so they are listed and
//  the person picks; none is a node that does not publish this server yet, so the page shows
//  the `tailscale serve` line that would and fills in nothing. Guessing would publish an
//  address that might not be the one clients can reach, which is worse than an empty field
//  because nothing would say it was guessed.
//
//  Decided here rather than on the view so it can be tested; see "Policy lives off the view"
//  in `CLAUDE.md`.

import BBBuiltIns
import BBSettings
import BlueBubblesServerCore
import Foundation

enum TailscaleHandoff: Equatable {
  /// Nothing to say: no Tailscale here, or one that is not signed in.
  case nothing
  /// Signed in and publishing this server at exactly one address.
  case publishedAt(machine: String?, address: String)
  /// Signed in and publishing this server at more than one address. The person picks.
  case publishedAtSeveral(machine: String?, addresses: [String])
  /// Signed in, and not publishing this server, or its serve config could not be read.
  /// Carries the command that would publish it.
  case notPublishing(machine: String?, serveCommand: String)

  init(_ found: TailscaleOnThisMac, serverPort: Int, originUsesTLS: Bool) {
    guard case .running(let machine, let publishing) = found else {
      self = .nothing
      return
    }
    let addresses: [String]
    switch publishing {
    case .addresses(let found): addresses = found
    case .unknown: addresses = []
    }
    switch addresses.count {
    case 0:
      self = .notPublishing(
        machine: machine,
        serveCommand: Self.serveCommand(port: serverPort, originUsesTLS: originUsesTLS))
    case 1:
      self = .publishedAt(machine: machine, address: addresses[0])
    default:
      self = .publishedAtSeveral(machine: machine, addresses: addresses)
    }
  }

  /// The line a person runs to publish this server through their own Tailscale.
  ///
  /// The same target the Tailscale method serves to (`TailscaleOptions.target(port:)`), so
  /// what they paste and what this server would have done agree. `--bg` keeps it after the
  /// terminal closes; with no `--https` it is served on 443, which gives the plainest address.
  static func serveCommand(port: Int, originUsesTLS: Bool) -> String {
    let scheme = originUsesTLS ? "https+insecure" : "http"
    return "tailscale serve --bg \(scheme)://127.0.0.1:\(port)"
  }

  var headline: String {
    switch self {
    case .nothing: ""
    case .publishedAt, .publishedAtSeveral:
      "Your own Tailscale already publishes this server"
    case .notPublishing:
      "Tailscale is already running on this Mac"
    }
  }

  var body: String {
    switch self {
    case .nothing:
      ""
    case .publishedAt(let machine, let address):
      "\(Self.node(machine)) serves this server at \(address). To keep managing Tailscale "
        + "yourself, switch to Custom URL with that address, and this server stops running "
        + "a Tailscale node of its own."
    case .publishedAtSeveral(let machine, _):
      "\(Self.node(machine)) serves this server at more than one address. Choose the one "
        + "clients should use to switch to Custom URL, and this server stops running a "
        + "Tailscale node of its own."
    case .notPublishing(let machine, _):
      "\(Self.node(machine)) is signed in to your tailnet. This page runs a separate node "
        + "for BlueBubbles and leaves yours alone. To publish this server through yours "
        + "instead, run this in Terminal, then come back and check again:"
    }
  }

  /// "The node bluebubbles-mac.example.ts.net", or "Your node" when it has no name yet.
  private static func node(_ machine: String?) -> String {
    machine.map { "The node \($0)" } ?? "Your node"
  }

  /// The addresses offered as buttons: one each, so the person's choice is the
  /// disambiguation.
  var offeredAddresses: [String] {
    switch self {
    case .publishedAt(_, let address): [address]
    case .publishedAtSeveral(_, let addresses): addresses
    case .nothing, .notPublishing: []
    }
  }
}

// MARK: - The two reads and the one write

@MainActor
extension AppModel {

  /// Looks for a Tailscale somebody else runs here, and decides what the page says.
  ///
  /// `.nothing` with no server, and when the lookup is cancelled: this is a shortcut on a
  /// page whose content is the Tailscale form below it, so "could not look" and "there is
  /// nothing" draw the same thing — no card — and the page is complete either way.
  func lookForTailscaleOnThisMac() async -> TailscaleHandoff {
    guard let lookup = connection.tailscaleOnThisMac else { return .nothing }
    do {
      let port = try await settings.get(Settings.socketPort)
      let usesTLS = try await settings.get(Settings.useCustomCertificate)
      let found = try await lookup.inspect(serverPort: port, originUsesTLS: usesTLS)
      return TailscaleHandoff(found, serverPort: port, originUsesTLS: usesTLS)
    } catch {
      return .nothing
    }
  }

  /// Switches the connection method to Custom URL, publishing `address`.
  ///
  /// The address first, then the method: the other order starts Custom URL with no address,
  /// which it refuses as a missing required field and reports, for the moment before the
  /// second write lands.
  ///
  /// - Parameter opensItsPage: on the Integrations screen, go to Custom URL's page so the
  ///   person sees what they switched to. Setup follows the selection on its own.
  func handOffTailscaleToCustomURL(_ address: String, opensItsPage: Bool) async {
    // Its one field, read off the manifest rather than named here, so the stored key has
    // one spelling: the declaration's.
    guard let customURL = IntegrationCatalog.manifest(BuiltInManifests.ID.proxyDynamicDNS),
      let field = customURL.fields.first(where: { $0.kind == .url })
    else { return }
    let settings = self.settings
    do {
      // `SettingsModel` already writes as the operator; said again here because inside the
      // model it is not reached as `model.settings`, which is how the attribution scan
      // recognises that door.
      try await asOperator {
        try await settings.set(
          address, forKey: customURL.storageKey(for: field.key), isSecret: field.isSecret)
      }
    } catch {
      await report(error, while: "switch to Custom URL")
      return
    }
    // Reports its own failure through `IntegrationsModel.onFailure`.
    await integrations.select(customURL)
    if opensItsPage { open(customURL.id) }
  }
}
