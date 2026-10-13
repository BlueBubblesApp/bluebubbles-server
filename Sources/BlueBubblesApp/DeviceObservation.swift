//  DeviceObservation
//  The registered push devices, followed for the life of the server.
//
//  The table is written by paths this process does not hear about: a client registering over
//  HTTP is the ordinary one, and the push sender pruning a token FCM has rejected is the one
//  that matters, because a device disappearing from the list is how somebody finds out their
//  phone stopped being reachable. Neither is an event on the bus, so a screen showing the
//  list had nothing to react to.
//
//  GRDB re-runs the read after every commit to `device`, whichever path wrote it, which is
//  the same mechanism the webhook registrations use and the reason neither page needs a
//  timer. See `Sources/BlueBubblesApp/CLAUDE.md`: a view never polls and never subscribes on
//  its own.

import BBAppStore
import Foundation

extension AppModel {

  /// Follows the device table. Cancelled by `stopFollowingServer`.
  func followPushDevices(_ repository: DeviceRepository) {
    countChanges(.pushDevices, of: { repository.changes() }, bump: { $0.pushDevicesVersion += 1 })
  }
}
