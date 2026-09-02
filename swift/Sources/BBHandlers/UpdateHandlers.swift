//  UpdateHandlers
//  `GET /server/update/check` and `POST /server/update/install`.
//
//  The check reads the same Sparkle appcast shipped installs read. That sharing is the point:
//  the current server polls the GitHub releases API while its updater reads something else, so
//  the API can report an update the updater will not install.
//
//  See `CONTRIBUTING.md`.

import BBHTTPAPI
import BBInterfaces
import BBSerialization
import BBSettings
import BBUpdates
import Foundation

public enum UpdateHandlers {

  public static func register(
    into registry: inout HandlerRegistry, context: some SettingsProviding & UpdateInstallerProviding
  ) {
    registry.register(.serverCheckUpdate) { _ in
      let checker = UpdateChecker(
        feedURL: await context.settings.get(Settings.updateFeedURL),
        currentVersion: ServerVersion.current
      )
      return .data(try await checker.check().json)
    }

    /// Installing requires a UI process.
    ///
    /// Sparkle relaunches the application, so there has to be an application to relaunch.
    /// A headless server has nothing to hand the update to — and a background process
    /// that replaced its own bundle and exited would look to the user like a crash.
    ///
    /// So this delegates to whatever is hosting the server, and says so plainly when
    /// nothing is. Returning a fake success would be worse than a clear refusal: the
    /// client would report "updating" and nothing would ever happen.
    registry.register(.serverInstallUpdate) { _ in
      let checker = UpdateChecker(
        feedURL: await context.settings.get(Settings.updateFeedURL),
        currentVersion: ServerVersion.current
      )
      let result = try await checker.check()

      guard result.isAvailable, let item = result.item else {
        throw BadRequest("there is no update to install; this server is up to date")
      }

      // Says what is true — no installer is available — without asserting WHY. Claiming the
      // server is running headless would be a guess this code cannot make: a GUI app with no
      // updater wired in reaches here too, and telling that user to "run the server inside
      // the BlueBubbles app" names something they are already doing.
      guard let installer = await context.updateInstaller else {
        throw ServiceUnavailable(
          """
          This server cannot install its own update — updating relaunches the \
          application, and no updater is available to this process. \
          Download \(item.downloadURL) and install it manually.
          """
        )
      }

      await installer.beginUpdate(to: item)
      return .data(
        .object([
          "installing": .bool(true),
          "version": .string(item.shortVersion),
        ]))
    }
  }
}
