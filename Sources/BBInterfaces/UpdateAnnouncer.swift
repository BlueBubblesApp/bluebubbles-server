//  UpdateAnnouncer
//  Tells clients a newer server exists, once per version.
//
//  The reference emits `server-update` whenever its check finds a release
//  (`updateService/index.ts:88-89`: `if (this.hasUpdate) emitMessage(SERVER_UPDATE,
//  latestVersion)`), and the Android and desktop clients show a notification for it. The
//  payload is the BARE version string, as `new-server`'s is the bare address; an object
//  here would be tidier and would break every client that reads the payload as the
//  version.
//
//  Once per version, not once per check. The reference stops checking after the first
//  find, so it emits once; this server keeps checking (three callers, one of them daily),
//  and re-emitting the same release every morning would notify every phone every morning.
//  A NEWER release found later is announced again, because it is news.
//
//  It also says when what is happening to a found release moves (downloading, scheduled for
//  a window, installing, nothing pending) as `server-update-status-changed`, so a client's
//  update page follows a schedule another client set, or the automatic one, without
//  polling. Once per CHANGE: the updater reports its state at every step of its wait, and
//  a client is told only when the answer differs.

import BBCore
import BBEvents
import BBSerialization
import BBUpdates
import Foundation

public actor UpdateAnnouncer {

  private let events: EventBus
  private var announcedVersion: String?
  /// The install state last announced. Starts as "nothing pending", which is what a client
  /// assumes of a server it has not heard from, so a first report of nil says nothing.
  private var announcedInstallState: UpdateInstallState?

  public init(events: EventBus) {
    self.events = events
  }

  /// Emits `server-update` for `version` unless it is the version already announced.
  /// - Returns: Whether an event went out, so a caller can log the first find and not the
  ///   twentieth.
  @discardableResult
  public func announce(version: String) async -> Bool {
    let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != announcedVersion else { return false }
    announcedVersion = trimmed
    await events.emit(ServerEvent(name: .serverUpdate, fullPayload: .string(trimmed)))
    return true
  }

  /// Emits `server-update-status-changed` unless `state` is what was last announced.
  ///
  /// The payload is `{"install": …}` with the same object `GET /api/v2/server/update`
  /// carries, or null once nothing is pending. Small and bounded, so it fits FCM's 4096
  /// bytes with no shedding: no release notes, which a client reads from the route.
  /// - Returns: Whether an event went out.
  @discardableResult
  public func announce(installState state: UpdateInstallState?) async -> Bool {
    guard state != announcedInstallState else { return false }
    announcedInstallState = state
    let payload: JSONValue = .object(["install": state?.json ?? .null])
    await events.emit(ServerEvent(name: .serverUpdateStatusChanged, fullPayload: payload))
    return true
  }
}
