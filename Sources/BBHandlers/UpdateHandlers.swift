//  UpdateHandlers
//  `GET /server/update/check` and `POST /server/update/install`, and v2's update page:
//  `GET /api/v2/server/update` and the `schedule` pair beside it.
//
//  The check reads the same Sparkle appcast shipped installs read. That sharing is the point:
//  the reference polls the GitHub releases API while its updater reads something else, so
//  the API can report an update the updater will not install. Both operations are
//  `UpdateInterface`; these parse the request and serialize.
//
//  See `CONTRIBUTING.md`.

import BBCore
import BBEvents
import BBHTTPAPI
import BBInterfaces
import BBSerialization
import BBSettings
import BBUpdates
import Foundation

public enum UpdateHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some SettingsProviding & UpdateInstallerProviding & EventPublishing & UpdateAnnouncing
  ) {
    registry.register(.serverCheckUpdate) { _ in
      .data(try await interface(context).check().json)
    }

    // Delegates to whatever hosts the server, and refuses plainly when nothing can install;
    // see `UpdateInterface.install`.
    registry.register(.serverInstallUpdate) { request in
      // `wait`, read the reference's way: `isTruthyBool` over a query string that defaults
      // to "false" (`serverRouter.ts:24`). `wait=true` means "answer when the download has
      // landed", which is what the reference does by awaiting `downloadUpdate()`.
      let outcome = try await interface(context).install(
        waitingForDownload: request.truthy("wait"))
      return .data(UpdateInterface.serialize(outcome))
    }

    registry.register(.serverUpdateStatus) { _ in
      .data(UpdateInterface.serialize(try await interface(context).status()))
    }

    // Both times absolute, in epoch MILLISECONDS like every other date on this API: the
    // person choosing the window may not be in this Mac's time zone, and an instant means
    // the same thing on both ends. The interface decides whether the window is usable;
    // this only refuses what cannot be a window at all.
    registry.register(.serverScheduleUpdate) { request in
      try await scheduleUpdate(request, context: context)
    }

    registry.register(.serverCancelScheduledUpdate) { _ in
      .data(UpdateInterface.serialize(try await interface(context).cancelSchedule()))
    }
  }

  /// `POST /api/v2/server/update/schedule`.
  ///
  /// Refuses only what cannot be a window at all; whether the window is usable is the
  /// interface's decision. Finite first: a form body's `"inf"` reads as a number, and an
  /// infinite date traps when the window is serialized back.
  private static func scheduleUpdate(
    _ request: APIRequestContext,
    context: some SettingsProviding & UpdateInstallerProviding & EventPublishing
      & UpdateAnnouncing
  ) async throws -> RouteResult {
    let values = try request.values()
    guard let start = values.double("window_start"), let end = values.double("window_end") else {
      throw BadRequest("`window_start` and `window_end` are both required, as epoch milliseconds")
    }
    guard start.isFinite, end.isFinite else {
      throw BadRequest("`window_start` and `window_end` must be finite epoch milliseconds")
    }
    // Before the interval is built: `DateInterval` traps on an end before its start.
    guard end > start else {
      throw BadRequest("`window_end` must be later than `window_start`")
    }
    let window = DateInterval(
      start: Date(epochMilliseconds: start), end: Date(epochMilliseconds: end))
    let status = try await interface(context).schedule(within: window)
    return .data(UpdateInterface.serialize(status))
  }

  /// Built per request over the installer as it is now: the app attaches one after start.
  private static func interface(
    _ context: some SettingsProviding & UpdateInstallerProviding & EventPublishing
      & UpdateAnnouncing
  ) async -> UpdateInterface {
    UpdateInterface(
      settings: context.settings,
      installer: await context.updateInstaller,
      events: context.events,
      announcer: context.updateAnnouncer,
      currentVersion: ServerVersion.current
    )
  }
}
