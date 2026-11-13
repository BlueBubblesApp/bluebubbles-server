//  WhatsNew
//  What to say on the first start after an update.
//
//  Sparkle installs and relaunches and says nothing afterwards; the "Installing X" alert
//  raised before the relaunch is a promise, and this is the half that keeps it. The
//  decision is a pure function of two version strings so it can be tested without a store,
//  and the alert it describes is raised by `UpdatesModel.noteVersionChange`, off the start
//  path, so a slow alert centre can never delay the server.

import BBCore
import BBUpdates

enum WhatsNew {

  struct Notice: Equatable {
    var title: String
    var body: String
    /// The release page for the running version.
    var notesURL: String
  }

  /// Nil when there is nothing to say: a fresh install (no previous version recorded), the
  /// same version as last time, or a rollback, which is not news anyone wants an alert for.
  static func notice(previous: String?, current: String) -> Notice? {
    let before = previous?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let now = current.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !before.isEmpty, !now.isEmpty, before != now else { return nil }
    guard SemanticVersion(now) > SemanticVersion(before) else { return nil }
    return Notice(
      title: "Updated to BlueBubbles \(now)",
      body: "This Mac was on \(before). The release notes say what changed.",
      notesURL: ReleasePages.notes(forVersion: now)
    )
  }
}
