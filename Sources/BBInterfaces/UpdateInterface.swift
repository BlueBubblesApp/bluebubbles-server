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
//
//  v2 adds the second thing a client can ask for besides "install now": "install inside this
//  window", for a server somebody does not want relaunching in the middle of the day. The
//  window is the CLIENT's, in absolute time, because the person choosing it may not be in
//  this Mac's time zone; the automatic hours, which are wall-clock hours on this Mac, are
//  reported beside it so a client can offer them as the default.

import BBCore
import BBEvents
import BBSerialization
import BBSettings
import BBUpdates
import Foundation

public struct UpdateInterface: Sendable {

  private let settings: SettingsStore
  private let installer: (any UpdateInstalling)?
  private let events: EventBus
  private let announcer: UpdateAnnouncer
  private let currentVersion: String
  private let calendar: Calendar
  private let fetch: (@Sendable (String) async throws -> Data)?

  /// - Parameter currentVersion: this build's version, which the caller knows and this layer
  ///   cannot: it is stamped into the binary above it.
  /// - Parameter calendar: the Mac's, whose time zone the automatic hours are in. A
  ///   parameter so a test can pin it.
  /// - Parameter fetch: reads the feed; nil for the network. A parameter so a test can hand
  ///   the checker a feed without one.
  public init(
    settings: SettingsStore,
    installer: (any UpdateInstalling)?,
    events: EventBus,
    announcer: UpdateAnnouncer,
    currentVersion: String,
    calendar: Calendar = .current,
    fetch: (@Sendable (String) async throws -> Data)? = nil
  ) {
    self.settings = settings
    self.installer = installer
    self.events = events
    self.announcer = announcer
    self.currentVersion = currentVersion
    self.calendar = calendar
    self.fetch = fetch
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
    let item = try Self.installable(try await checker().check())

    // Says what is true (no installer is available) without asserting WHY. A GUI app with no
    // updater wired in reaches here too, and telling that user to "run the server inside the
    // BlueBubbles app" names something they are already doing.
    let installer = try requireInstaller(for: item)

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

  // MARK: - v2: what a client's update page shows, and scheduling

  /// The automatic install, as the settings on this Mac describe it.
  public struct AutomaticInstall: Sendable, Equatable {
    /// Check for Updates and Install Updates Automatically both on: the daily check is what
    /// finds and downloads a release, so the second switch does nothing without the first.
    public let isEnabled: Bool
    public let hours: DailyInstallHours
    /// The window those hours open next, or the one open now. Reported whether or not the
    /// switch is on, so a client can offer it as the default window to ask for.
    public let nextWindow: DateInterval
    public let timeZone: TimeZone
  }

  /// What `GET /api/v2/server/update` reports.
  public struct Status: Sendable, Equatable {
    /// What the feed offers, with the install state attached.
    public let check: UpdateCheckResult
    /// Whether this process can install at all. False under the headless CLI and on a build
    /// without an update signing key, where install and schedule both refuse.
    public let canInstall: Bool
    /// The window a client asked for, at its next occurrence; nil when none was asked for.
    public let requestedWindow: DateInterval?
    public let automatic: AutomaticInstall
  }

  /// How far ahead a requested window may close. A week covers "this weekend", and a window
  /// further out is more likely a unit mistake (milliseconds sent as microseconds lands in
  /// the year 50,000) than a plan.
  public static let longestScheduleLead: TimeInterval = 7 * 24 * 60 * 60

  /// How long a requested window may last. A day, because a window that closes without the
  /// install comes round the next day: longer, and the next day's would overlap this one.
  /// It also bounds the start, which the end alone does not.
  public static let longestWindow: TimeInterval = 24 * 60 * 60

  /// Everything a client's update page shows.
  public func status(now: Date = Date()) async throws -> Status {
    let result = try await check()
    return await status(from: result, now: now)
  }

  /// Downloads the newest release now and holds its relaunch for `window`.
  ///
  /// The window is absolute time. A start already past means "from now"; an end already
  /// past is refused, because there is no window left to hold anything for.
  public func schedule(within window: DateInterval, now: Date = Date()) async throws -> Status {
    guard window.end > now else {
      throw InterfaceError.invalidRequest(
        "window_end has already passed; schedule a window that ends in the future")
    }
    guard window.end <= now.addingTimeInterval(Self.longestScheduleLead) else {
      throw InterfaceError.invalidRequest(
        "window_end is more than seven days away; both times are epoch milliseconds")
    }
    guard window.duration <= Self.longestWindow else {
      throw InterfaceError.invalidRequest(
        "the window is longer than a day; one that closes without the install is tried "
          + "again the next day, so a day is the longest it can be")
    }
    let result = try await checker().check()
    let item = try Self.installable(result)
    let installer = try requireInstaller(for: item)
    await announcer.announce(version: item.shortVersion)

    switch await installer.scheduleUpdate(to: item, within: window) {
    case .scheduled:
      break
    case .busy:
      throw InterfaceError.unavailable(
        "Somebody at this Mac has the updater open, so this update is theirs to install. "
          + "Try again once its window is closed.")
    case .needsPerson:
      throw InterfaceError.unavailable(
        "This installation cannot install an update without a person at the Mac, so it "
          + "cannot keep a schedule. Install \(item.shortVersion) from the Mac instead.")
    }
    return await status(from: result, now: now)
  }

  /// Withdraws the window a client asked for.
  ///
  /// Answers with the status either way, because "nothing was scheduled" is the state the
  /// caller wanted. An automatic schedule is not withdrawn: it is a setting on the Mac, and
  /// the status shows it still standing, with `scheduled_by: automatic`.
  ///
  /// The withdrawal comes before the feed is read: an unreachable feed fails the answer, and
  /// must not leave the window standing behind the failure.
  public func cancelSchedule(now: Date = Date()) async throws -> Status {
    guard let installer else {
      throw InterfaceError.unavailable(
        "This server cannot install its own update, so nothing can be scheduled on it.")
    }
    await installer.cancelScheduledUpdate()
    return try await status(now: now)
  }

  /// The status around a check already made, with the installer's state read AFTER whatever
  /// the caller asked it to do.
  private func status(from result: UpdateCheckResult, now: Date) async -> Status {
    var result = result
    result.install = await installer?.installState
    let requested = await installer?.requestedInstallWindow
    let hours = DailyInstallHours(
      startHour: await settings.get(Settings.autoInstallHour),
      endHour: await settings.get(Settings.autoInstallEndHour))
    let checks = await settings.get(Settings.checkForUpdates)
    let installs = await settings.get(Settings.autoInstallUpdates)
    return Status(
      check: result,
      canInstall: installer != nil,
      requestedWindow: requested.map {
        InstallSchedule.requested($0).window(containingOrAfter: now, calendar: calendar)
      },
      automatic: AutomaticInstall(
        isEnabled: checks && installs,
        hours: hours,
        nextWindow: hours.window(containingOrAfter: now, calendar: calendar),
        timeZone: calendar.timeZone
      )
    )
  }

  /// The release a check offered, or the refusal `install` has always given.
  private static func installable(_ result: UpdateCheckResult) throws -> AppcastItem {
    guard result.isAvailable, let item = result.item else {
      throw InterfaceError.invalidRequest(
        "there is no update to install; this server is up to date")
    }
    return item
  }

  /// The installer, or the refusal that names the download to install by hand.
  private func requireInstaller(for item: AppcastItem) throws -> any UpdateInstalling {
    guard let installer else {
      throw InterfaceError.unavailable(
        """
        This server cannot install its own update; updating relaunches the \
        application, and no updater is available to this process. \
        Download \(item.downloadURL) and install it manually.
        """
      )
    }
    return installer
  }

  /// `GET /api/v2/server/update`'s `data`, and the answer to scheduling and cancelling.
  ///
  /// snake_case, and dates in epoch milliseconds, `release_date` included: v1's ISO string
  /// there is the exception v1 is frozen with, and v2 has no reason to repeat it.
  public static func serialize(_ status: Status) -> JSONValue {
    var object = JSONObjectBuilder()
    object.set("current_version", .string(status.check.currentVersion))
    object.set("available", .bool(status.check.isAvailable))
    if status.check.isAvailable, let item = status.check.item {
      var update = JSONObjectBuilder()
      update.set("version", .string(item.shortVersion))
      update.set("release_name", .string(item.title))
      update.set(
        "release_date",
        .int64(item.publishedAt.epochMilliseconds(rounded: .toNearestOrAwayFromZero)))
      update.setOrNull("release_notes", item.releaseNotesHTML.map(JSONValue.string))
      update.set("release_notes_url", .string(ReleasePages.notes(forVersion: item.shortVersion)))
      object.set("update", update.build())
    } else {
      object.setOrNull("update", nil)
    }
    object.setOrNull("install", status.check.install.map(\.json))
    object.set("can_install", .bool(status.canInstall))
    object.setOrNull("requested_window", status.requestedWindow.map(Self.serialize(window:)))

    var automatic = JSONObjectBuilder()
    automatic.set("enabled", .bool(status.automatic.isEnabled))
    automatic.set("start_hour", .int(status.automatic.hours.startHour))
    automatic.set("end_hour", .int(status.automatic.hours.endHour))
    automatic.set("time_zone", .string(status.automatic.timeZone.identifier))
    automatic.set("next_window", serialize(window: status.automatic.nextWindow))
    object.set("automatic_install", automatic.build())
    return object.build()
  }

  private static func serialize(window: DateInterval) -> JSONValue {
    var object = JSONObjectBuilder()
    object.set("start", .int64(window.start.epochMilliseconds(rounded: .toNearestOrAwayFromZero)))
    object.set("end", .int64(window.end.epochMilliseconds(rounded: .toNearestOrAwayFromZero)))
    return object.build()
  }

  /// One checker for every operation, reading the settings the app hands Sparkle.
  private func checker() async -> UpdateChecker {
    let beta = await settings.get(Settings.receiveBetaUpdates)
    return UpdateChecker(
      feedURL: await settings.get(Settings.updateFeedURL),
      currentVersion: currentVersion,
      allowedChannels: beta ? [UpdateChecker.betaChannel] : [],
      fetch: fetch
    )
  }
}
