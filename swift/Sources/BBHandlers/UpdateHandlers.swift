//  UpdateHandlers
//  `GET /server/update/check` and `POST /server/update/install`.
//
//  The check reads the same Sparkle appcast shipped installs read. That sharing is the point:
//  the reference polls the GitHub releases API while its updater reads something else, so
//  the API can report an update the updater will not install.
//
//  See `CONTRIBUTING.md`.

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
      var result = try await makeChecker(context).check()
      // The reference announces a find from its check path too (`updateService`), and a
      // client polling this endpoint is not the only one that wants to know.
      if result.isAvailable, let item = result.item {
        await context.updateAnnouncer.announce(version: item.shortVersion)
      }
      result.install = await context.updateInstaller?.installState
      return .data(result.json)
    }

    /// Installing requires a UI process.
    ///
    /// Sparkle relaunches the application, so there has to be an application to relaunch.
    /// A headless server has nothing to hand the update to, and a background process
    /// that replaced its own bundle and exited would look to the user like a crash.
    ///
    /// So this delegates to whatever is hosting the server, and says so plainly when
    /// nothing is. Returning a fake success would be worse than a clear refusal: the
    /// client would report "updating" and nothing would ever happen.
    registry.register(.serverInstallUpdate) { request in
      // `wait`, read the reference's way: `isTruthyBool` over a query string that defaults
      // to "false" (`serverRouter.ts:24`).
      let wait = request.truthy("wait")
      let result = try await makeChecker(context).check()

      guard result.isAvailable, let item = result.item else {
        throw BadRequest("there is no update to install; this server is up to date")
      }

      // Says what is true (no installer is available) without asserting WHY. Claiming the
      // server is running headless would be a guess this code cannot make: a GUI app with no
      // updater wired in reaches here too, and telling that user to "run the server inside
      // the BlueBubbles app" names something they are already doing.
      guard let installer = await context.updateInstaller else {
        throw ServiceUnavailable(
          """
          This server cannot install its own update; updating relaunches the \
          application, and no updater is available to this process. \
          Download \(item.downloadURL) and install it manually.
          """
        )
      }

      // Announced BEFORE the work starts, with a null payload, which is what the reference
      // does (`serverRouter.ts:35`, `emitMessage(SERVER_UPDATE_DOWNLOADING, null)` ahead of
      // `autoUpdater.downloadUpdate()`). A client that asked for the install is the one
      // listening, and the relaunch that follows is why it has to hear now.
      await context.events.emit(
        ServerEvent(name: .serverUpdateDownloading, fullPayload: .null))
      await installer.beginUpdate(to: item)

      // `wait=true` means "answer when the download has landed", which is what the reference
      // does by awaiting `downloadUpdate()`. The wait is bounded: this is an HTTP request,
      // and a stalled download must not hold the connection until the route timeout answers
      // nothing at all. What actually happened goes on the response, because "still
      // downloading" and "downloaded" are different answers and a client that asked for this
      // flag is the one client that cares which it got.
      var downloaded: UpdateDownloadOutcome?
      if wait {
        downloaded = await installer.awaitDownload(timeout: .seconds(600))
      }

      var body: [String: JSONValue] = [
        "installing": .bool(true),
        "version": .string(item.shortVersion),
      ]
      if let downloaded {
        body["downloaded"] = .bool(downloaded == .downloaded)
        switch downloaded {
        case .downloaded: body["state"] = .string("downloaded")
        case .timedOut: body["state"] = .string("downloading")
        case .notDownloading: body["state"] = .string("not-downloading")
        case .failed(let reason):
          body["state"] = .string("failed")
          body["error"] = .string(reason)
        }
      }
      return .data(.object(body))
    }
  }
}

extension UpdateHandlers {
  /// One checker for both routes, reading the same settings the app hands Sparkle, so
  /// "is there an update" has one answer on this server whoever asks.
  fileprivate static func makeChecker(_ context: some SettingsProviding) async -> UpdateChecker {
    let beta = await context.settings.get(Settings.receiveBetaUpdates)
    return UpdateChecker(
      feedURL: await context.settings.get(Settings.updateFeedURL),
      currentVersion: ServerVersion.current,
      allowedChannels: beta ? [UpdateChecker.betaChannel] : []
    )
  }
}
