//  UpdateHandlers
//  `GET /server/update/check` and `POST /server/update/install`.
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
