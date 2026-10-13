//  UpdateInterface
//  Checking for a newer server, and handing one to whatever can install it.
//
//  The check reads the same Sparkle appcast shipped installs read, through the same settings
//  the app hands Sparkle, so "is there an update" has one answer on this server whoever asks.
//
//  Installing needs a UI process: Sparkle relaunches the application, so there has to be an
//  application to relaunch. This delegates to whatever hosts the server (`UpdateInstalling`)
//  and says plainly when nothing does. A fake success would be worse than a clear refusal:
//  the client would report "updating" and nothing would ever happen.

import BBCore
import BBEvents
import BBSettings
import BBUpdates
import Foundation

public struct UpdateInterface: Sendable {

  private let settings: SettingsStore
  private let installer: (any UpdateInstalling)?
  private let events: EventBus
  private let announcer: UpdateAnnouncer
  private let currentVersion: String

  /// - Parameter currentVersion: this build's version, which the caller knows and this layer
  ///   cannot: it is stamped into the binary above it.
  public init(
    settings: SettingsStore,
    installer: (any UpdateInstalling)?,
    events: EventBus,
    announcer: UpdateAnnouncer,
    currentVersion: String
  ) {
    self.settings = settings
    self.installer = installer
    self.events = events
    self.announcer = announcer
    self.currentVersion = currentVersion
  }

  /// What the feed offers, with any install already under way attached.
  ///
  /// A find is ANNOUNCED as well as returned: a client polling this is not the only one that
  /// wants to know, and the announcer says each version once whoever finds it.
  public func check() async throws -> UpdateCheckResult {
    var result = try await checker().check()
    if result.isAvailable, let item = result.item {
      await announcer.announce(version: item.shortVersion)
    }
    result.install = await installer?.installState
    return result
  }

  /// What an install request did.
  public struct InstallOutcome: Sendable, Equatable {
    /// The release being installed.
    public let version: String
    /// How the download ended, when the caller asked to wait for it; nil when it did not.
    public let download: UpdateDownloadOutcome?
  }

  /// Hands the newest release to the installer.
  ///
  /// - Parameter waitingForDownload: answer when the download has landed rather than when it
  ///   has started. Bounded, because the caller is usually an HTTP request and a stalled
  ///   download must not hold it until the route timeout answers nothing at all; what actually
  ///   happened is in the outcome, because "still downloading" and "downloaded" are different
  ///   answers.
  public func install(waitingForDownload: Bool) async throws -> InstallOutcome {
    let result = try await checker().check()
    guard result.isAvailable, let item = result.item else {
      throw InterfaceError.invalidRequest(
        "there is no update to install; this server is up to date")
    }

    // Says what is true (no installer is available) without asserting WHY. A GUI app with no
    // updater wired in reaches here too, and telling that user to "run the server inside the
    // BlueBubbles app" names something they are already doing.
    guard let installer else {
      throw InterfaceError.unavailable(
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
    await events.emit(ServerEvent(name: .serverUpdateDownloading, fullPayload: .null))
    await installer.beginUpdate(to: item)

    let download =
      waitingForDownload ? await installer.awaitDownload(timeout: .seconds(600)) : nil
    return InstallOutcome(version: item.shortVersion, download: download)
  }

  /// `POST /server/update/install`'s `data`: the version, and how the download ended when the
  /// caller waited for it.
  public static func serialize(_ outcome: InstallOutcome) -> JSONValue {
    var body: [String: JSONValue] = [
      "installing": .bool(true),
      "version": .string(outcome.version),
    ]
    if let downloaded = outcome.download {
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
    return .object(body)
  }

  /// One checker for both operations, reading the settings the app hands Sparkle.
  private func checker() async -> UpdateChecker {
    let beta = await settings.get(Settings.receiveBetaUpdates)
    return UpdateChecker(
      feedURL: await settings.get(Settings.updateFeedURL),
      currentVersion: currentVersion,
      allowedChannels: beta ? [UpdateChecker.betaChannel] : []
    )
  }
}
