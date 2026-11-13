//  IMCoreCloudSync
//  Messages in iCloud: reading its state and asking for a sync.
//
//  Settings > iMessage > Sync Now is `-[IMCloudKitEventNotificationManager
//  startUserInitiatedSync]`, and that method does nothing but fetch the manager's
//  `IMCloudKitHooks` and forward the same selector to it; the hooks hand the request to the
//  daemon. So this calls the hooks directly. Driving the settings window instead (open it,
//  find the button, press it) needs a logged-in screen, breaks on every relabelling of the
//  pane, and cannot report whether anything happened.
//
//  The state is read from two objects because they answer different questions. The hooks
//  carry the three values every release has (enabled, syncing, last sync), and those are
//  required. `IMCloudKitSyncState`, reached through the manager, adds paused, failed and the
//  status line, and is OPTIONAL: a release where the manager or a getter is missing still
//  answers the first three. See `CloudSyncState`.
//
//  Every selector here is in `IMCloudKitHooks.h`, `IMCloudKitSyncState.h` and
//  `IMCloudKitEventNotificationManager.h` under each of `docs/headers/macos-14.6.1`,
//  `macos-15.6.1`, `macos-26.6.2` and `macos-27.0.1`, with the same signature, so nothing here
//  is guarded by version. All take no arguments, and the BOOL getters go through
//  `IMCoreRuntime.bool`, which checks the return type rather than reading a byte as a pointer.

import BBPrivateAPIContract
import Foundation
import HelperShared

enum IMCloudSync {

  static func hooks() throws -> AnyObject {
    try IMCoreRuntime.sharedInstance(ofClass: "IMCloudKitHooks")
  }

  /// Asks the daemon for a sync now. Refused when Messages in iCloud is off, because the
  /// daemon accepts the request and does nothing, which a caller would read as success.
  static func start() throws {
    let hooks = try hooks()
    guard try IMCoreRuntime.bool(hooks, "isEnabled") else {
      throw PrivateAPIErrorShim.rejected(
        "Messages in iCloud is turned off on this Mac. Turn it on in Messages > Settings > "
          + "iMessage before asking for a sync."
      )
    }
    try IMCoreRuntime.send(hooks, "startUserInitiatedSync")
  }

  static func state() throws -> CloudSyncState {
    let hooks = try hooks()
    // `isStartingSync` covers the gap between asking and the daemon reporting a running
    // sync, which is exactly when a client that just pressed the button reads this.
    let starting = optionalBool(hooks, "isStartingSync") ?? false
    let syncing = try IMCoreRuntime.bool(hooks, "isSyncing")
    let detail = syncStateObject()
    return CloudSyncState(
      isEnabled: try IMCoreRuntime.bool(hooks, "isEnabled"),
      isSyncing: starting || syncing,
      lastSyncDate: try IMCoreRuntime.send(hooks, "lastSyncDate") as? Date,
      isPaused: detail.flatMap { optionalBool($0, "isSyncingPaused") },
      failed: detail.flatMap { optionalBool($0, "syncingFailed") },
      statusText: detail.flatMap { optionalString($0, "syncStatusText") }
    )
  }

  /// The manager's `IMCloudKitSyncState`, or nil where it cannot be had.
  ///
  /// Nil rather than a throw: the three fields it supplies are optional on the contract,
  /// and losing them must not cost the three that the hooks answered.
  private static func syncStateObject() -> AnyObject? {
    guard IMCoreRuntime.lookUpClass("IMCloudKitEventNotificationManager") != nil else {
      return nil
    }
    // A `try?` because the failure has somewhere to go: the fields this object supplies
    // are reported absent, which is the contract's "this Mac could not say".
    guard
      let manager = try? IMCoreRuntime.sharedInstance(
        ofClass: "IMCloudKitEventNotificationManager"),
      IMCoreRuntime.responds(manager, to: "syncState")
    else { return nil }
    return (try? IMCoreRuntime.send(manager, "syncState")) ?? nil
  }

  // Each `try?` below reports a getter this release lacks, or one that raised, as absent.
  private static func optionalBool(_ target: AnyObject, _ selector: String) -> Bool? {
    guard IMCoreRuntime.responds(target, to: selector) else { return nil }
    return try? IMCoreRuntime.bool(target, selector)
  }

  private static func optionalString(_ target: AnyObject, _ selector: String) -> String? {
    guard IMCoreRuntime.responds(target, to: selector) else { return nil }
    return (try? IMCoreRuntime.string(target, selector)) ?? nil
  }
}
