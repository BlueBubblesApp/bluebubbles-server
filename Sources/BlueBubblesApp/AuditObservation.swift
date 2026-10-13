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
//  Two costs are kept down, because the table is written up to ten times a second on a busy
//  server and this follows it for the life of the app. The version read is two primary-key
//  lookups (see `AuditTableVersion`), so following it costs nothing whether or not the page
//  is open. And the counter moves at most once a second: each move re-reads the open page,
//  and that read counts the matching rows, which is the expensive part.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`: a view never polls and never subscribes on its own.

import BBAudit
import Foundation

extension AppModel {

  /// The most often the Audit Log page re-reads while records are being written.
  static let auditRereadInterval: Duration = .seconds(1)

  /// Follows the audit table. Cancelled by `stopFollowingServer`.
  func followAuditLog(_ repository: AuditRepository) {
    countChanges(
      .auditEvents, of: { repository.changes() }, atMostEvery: Self.auditRereadInterval,
      bump: { $0.auditEventsVersion += 1 })
  }
}
