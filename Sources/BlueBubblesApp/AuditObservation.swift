//  AuditObservation
//  The audit table, followed for the life of the server.
//
//  Almost every row in `audit_event` is written by something other than the page that shows
//  it: a request finishing, a setting changing on another screen, a service restarting, the
//  retention sweep. None of those is an event on the bus, so the page has nothing to react
//  to unless the table itself is followed. GRDB re-runs the version read after every commit,
//  whichever path wrote, which is the mechanism the webhook registrations and the device list
//  already use and the reason this page needs no timer either.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`: a view never polls and never subscribes on its own.

import BBAudit
import Foundation

extension AppModel {

  /// Follows the audit table. Cancelled by `stopFollowingServer`.
  ///
  /// Needs no seed read: the observation's first element is the current version, so the
  /// counter moves once as soon as it attaches and the page reads from a standing start.
  func followAuditLog(_ repository: AuditRepository) {
    auditEventsTask?.cancel()
    auditEventsTask = Task { [weak self] in
      do {
        for try await _ in repository.changes() {
          // Only that something changed. The rows are the page's to read, through its
          // `ScreenModel`, so a read that fails lands where the page can say so; handing
          // the rows over here would make a failed read look like an empty list.
          self?.auditEventsVersion += 1
        }
      } catch {
        // The observation failed, which means the database did. The page's next read fails
        // the same way and says so; there is nothing to add here.
      }
    }
  }
}
