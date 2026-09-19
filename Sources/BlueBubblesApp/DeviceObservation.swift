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
  ///
  /// Needs no seed read: the observation's first element is the current table, so the
  /// counter moves once as soon as it attaches and the page reads from a standing start.
  func followPushDevices(_ repository: DeviceRepository) {
    pushDevicesTask?.cancel()
    pushDevicesTask = Task { [weak self] in
      do {
        for try await _ in repository.changes() {
          // Only that something changed. The rows are the page's to read, through its
          // `ScreenModel`, so a read that fails lands where the page can say so; handing
          // the rows over here would make a failed read look like an empty list.
          self?.pushDevicesVersion += 1
        }
      } catch {
        // The observation failed, which means the database did. The page's next read fails
        // the same way and says so; there is nothing to add here.
      }
    }
  }
}
