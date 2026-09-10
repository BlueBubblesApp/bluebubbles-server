//  AddressObservation
//  The address clients connect to, followed for the life of the server.
//
//  On the model rather than read per screen because three places want it and one of them
//  cannot read it for itself: the menu-bar menu has no `.task` to hang a settings read on,
//  and copying the address from there (without opening a window) is the thing a
//  menu-bar server is for.
//
//  The connection method writes this on every connect and reconnect, so it is followed
//  rather than read once, the same way every other live value is.

import BBSettings
import Foundation

extension AppModel {

  /// Follows `server_address`. Cancelled by `stopFollowingServer`.
  ///
  /// Subscribed before the seed read, so a publish landing between the two is not missed,
  /// which is the normal case here, since a tunnel publishes seconds after start.
  func followPublishedAddress(_ store: SettingsStore) {
    addressTask?.cancel()
    addressTask = Task { [weak self] in
      let changes = await store.changes()
      self?.publishedAddress = await store.get(Settings.serverAddress)
      for await change in changes where change.contains(Settings.serverAddress.key) {
        self?.publishedAddress = await store.get(Settings.serverAddress)
      }
    }
  }
}
