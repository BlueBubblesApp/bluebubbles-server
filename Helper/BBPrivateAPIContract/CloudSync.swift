//  BBPrivateAPIContract: CloudSync
//  Messages in iCloud: whether it is on, whether a sync is running, and when one last ran.
//
//  This is the state behind the "Sync Now" button in Messages > Settings > iMessage, read
//  out of IMCore rather than off that window. Asking for a sync is a call to
//  `-[IMCloudKitHooks startUserInitiatedSync]`, which hands the request to the daemon; the
//  window is not involved, so nothing here needs Messages to be in front, or a screen at all.
//
//  Foundation only, like everything in this module: it travels into Messages.app.

import Foundation

/// What Messages knows about its own iCloud sync.
///
/// Three fields from `IMCloudKitHooks`, and three that come from `IMCloudKitSyncState`, a
/// separate object built from the daemon's last broadcast. Every supported release has all
/// six getters (`docs/PRIVATE_API_SURFACE.md` §3c), but the second three are reached through
/// a second singleton and are OPTIONAL anyway: their absence means "this Mac could not say",
/// never "no". A `false` for `isPaused` that nobody read would tell a client the sync is
/// running when nobody knows.
public struct CloudSyncState: Codable, Sendable, Equatable {
  /// Messages in iCloud is switched on for this account on this Mac. When it is off,
  /// nothing syncs and a request to start one is refused.
  public let isEnabled: Bool
  /// A sync is running, or has been asked for and has not started yet. Both are "do not
  /// ask again", which is the question a client has.
  public let isSyncing: Bool
  /// When the last sync finished. Nil when this Mac has never completed one.
  public let lastSyncDate: Date?
  /// Messages has paused syncing, which it does on low battery or a constrained network.
  public let isPaused: Bool?
  /// The last sync ended in an error.
  public let failed: Bool?
  /// The line Messages shows under the Sync Now button, in the Mac's own language. For a
  /// person to read, never to branch on.
  public let statusText: String?

  public init(
    isEnabled: Bool,
    isSyncing: Bool,
    lastSyncDate: Date?,
    isPaused: Bool? = nil,
    failed: Bool? = nil,
    statusText: String? = nil
  ) {
    self.isEnabled = isEnabled
    self.isSyncing = isSyncing
    self.lastSyncDate = lastSyncDate
    self.isPaused = isPaused
    self.failed = failed
    self.statusText = statusText
  }
}
