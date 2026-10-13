//  AddressObservation
//  The address clients connect to, and the port the listener binds, followed for the life of
//  the server.
//
//  On the model rather than read per screen because six places want it and one of them
//  cannot read it for itself: the menu-bar menu has no `.task` to hang a settings read on,
//  and copying the address from there (without opening a window) is the thing a menu-bar
//  server is for. The other five (Home, Guides, API & Webhooks, a tunnel's own page and the
//  setup step) each derived it themselves and disagreed: two read it once and went stale
//  when a tunnel republished, two fell back to `localhost` where the others said nothing was
//  published, and one started from a hard-coded port.
//
//  The connection method writes the address on every connect and reconnect, so it is
//  followed rather than read once, the same way every other live value is. What a screen
//  shows for it is `ServerAddressRow`'s.

import BBSettings
import Foundation

/// Where this server can be reached, as the settings store has it.
///
/// One value, so a screen never shows a new address beside the previous port: the two are
/// read together on every write to either.
struct ClientAddress: Equatable, Sendable {

  /// What the running connection method last published. Empty until it has published,
  /// which is a real state and not an error: a tunnel takes a few seconds to come up.
  var published = ""
  /// The port the HTTP listener binds. Nil when there is no server to ask.
  var port: Int?

  /// Nothing known: no server.
  static let unknown = ClientAddress()

  /// An address a request made FROM THIS MAC can use: the published one, else the listener
  /// on `localhost`. Never shown to a person as the address to type into a phone, where
  /// `localhost` is the phone itself; only for a request this app makes or offers to make
  /// (the API reference's samples).
  var forThisMac: String? {
    if !published.isEmpty { return published }
    return port.map { "http://localhost:\($0)" }
  }
}

extension AppModel {

  /// Follows `server_address` and `socket_port`. Cancelled, and cleared, by
  /// `stopFollowingServer`.
  ///
  /// Subscribed before the seed read, so a publish landing between the two is not missed,
  /// which is the normal case here, since a tunnel publishes seconds after start.
  func followClientAddress(_ store: SettingsStore) {
    let keys: Set<String> = [Settings.serverAddress.key, Settings.socketPort.key]
    follow(
      .clientAddress,
      subscribe: { await store.changes() },
      seed: { $0.clientAddress = await Self.readClientAddress(store) },
      apply: { model, change in
        guard change.intersects(keys) else { return }
        model.clientAddress = await Self.readClientAddress(store)
      },
      reset: { $0.clientAddress = .unknown })
  }

  private static func readClientAddress(_ store: SettingsStore) async -> ClientAddress {
    ClientAddress(
      published: await store.get(Settings.serverAddress),
      port: await store.get(Settings.socketPort))
  }
}

extension AppModel {

  /// The address to hand a client, or empty when there is none to hand over: nothing
  /// published yet, or published and nothing listening behind it (`APIReachability`). The
  /// menu bar's Copy and `ServerAddressRow` both read this, so a copy is never offered of
  /// an address the page beside it says is not answering.
  var addressToShare: String {
    apiReachability.showsAddress ? clientAddress.published : ""
  }
}
