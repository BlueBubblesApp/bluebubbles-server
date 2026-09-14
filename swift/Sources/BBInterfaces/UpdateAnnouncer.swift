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

import BBEvents
import BBSerialization
import Foundation

public actor UpdateAnnouncer {

  private let events: EventBus
  private var announcedVersion: String?

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
}
