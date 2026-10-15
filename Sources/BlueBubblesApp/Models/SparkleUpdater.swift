//  SparkleUpdater
//  The app's updater: Sparkle, owned here because installing an update relaunches the
//  application, and only the application can be relaunched.
//
//  Four things reach it. The menu item calls `checkForUpdates`, which runs Sparkle's own
//  windows. The daily schedule is Sparkle's, switched by `check_for_updates`. And two client
//  requests reach it through `UpdateInstalling`, with nobody at the Mac, so both download in
//  the background with no dialog: `POST /server/update/install` takes the install-and-
//  relaunch handler the moment Sparkle offers it (or at once, when a download is already
//  waiting for its window), and `POST /api/v2/server/update/schedule` takes it and waits
//  for the window the client chose.
//
//  What a person sees, and where, is decided here rather than left to Sparkle's defaults:
//
//  - A check they asked for gets Sparkle's window, always.
//  - A scheduled find is a GENTLE reminder unless Sparkle judges the moment right (the app
//    just launched, or the Mac has been idle): a system notification, a card on Home and an
//    alert in the bell, each of which brings Sparkle's window forward on request. This is a
//    server that runs all day on a Mac someone is using for other things; a window that
//    steals focus at 3pm because a static file changed is the wrong default.
//  - A remote install says what it is about to do, in the bell and in the sidebar strip,
//    because the app is about to vanish and relaunch with no window of its own.
//  - An automatic install relaunches inside the window `auto_install_hour` to
//    `auto_install_end_hour` names, not on quit (a server never quits) and not after a
//    week's nag. A client's window replaces those hours for the update it was asked for.
//    `InstallSchedule` (`BBUpdates`) decides the moment, so the API reports the same one,
//    and `InstallWindow` holds it while a scheduled message is about to go out. Same notices
//    as above.
//  - Every move of `installState` goes to clients as `server-update-status-changed`, so a
//    client's update page follows a schedule another client set.
//  - Every find, whichever path made it, goes to clients as `server-update` through the
//    server's `UpdateAnnouncer`, once per version.
//
//  It does not start on a bundle whose `SUPublicEDKey` is blank; see `UpdaterPolicy`. Then
//  the installer seam stays empty, so the endpoint refuses exactly as it did before this
//  type existed, and the menu falls back to `UpdatesModel.check(userInitiated:)`.
//
//  Settings are read at attach and followed from the store's change stream. Sparkle asks
//  the delegate for the feed URL synchronously on the main thread, so the value is cached
//  here rather than awaited. The updater outlives the server: a stopped server is not a
//  reason to stop offering updates, so `detach` only stops following the store, and the
//  last values read stay in force until the next attach.

import AppKit
import BBCore
import BBDiagnostics
import BBInterfaces
import BBSettings
import BBUpdates
import Foundation
import Logging
import Observation
import Sparkle
import UserNotifications

@Observable
@MainActor
final class SparkleUpdater: NSObject {

  /// Decided once, from the bundle, before Sparkle is asked anything.
  let availability: UpdaterPolicy.Availability
  var isAvailable: Bool { availability == .available }

  /// A release a scheduled check found and this type chose not to interrupt with. Home
  /// draws it; it clears when the person gives Sparkle's window their attention or the
  /// session ends.
  private(set) var availableVersion: String?

  /// What is happening to an update already found: downloading, waiting for its window, or
  /// relaunching. Reported on `GET /server/update/check` and `GET /api/v2/server/update`
  /// through the installer seam, and to clients as it moves; the sidebar strip draws the
  /// last stage. Written only through `setInstallState`, which is what announces it.
  private(set) var installState: UpdateInstallState?

  /// The version a relaunch is bringing in, from the notice until the process is gone.
  var installingVersion: String? {
    if case .installing(let version) = installState { return version }
    return nil
  }

  @ObservationIgnored private var controller: SPUStandardUpdaterController?
  @ObservationIgnored private var store: SettingsStore?
  @ObservationIgnored private var alerts: AlertCenter?
  @ObservationIgnored private var announcer: UpdateAnnouncer?
  private let followTask = OwnedTask()

  /// Answers "may the app relaunch right now?" for a scheduled install. Supplied by
  /// `AppModel`, which can see the schedule; `InstallWindow.isQuiet` is the rule. Absent,
  /// the answer is yes: there is nothing to consult.
  @ObservationIgnored var isQuiet: (@MainActor () async -> Bool)?

  /// The scheduled install waiting for its window, so a second download, a settings change
  /// or a client's request replaces it rather than racing it.
  private let scheduledInstall = OwnedTask()

  /// The downloaded update and Sparkle's handler for installing it now, kept so the relaunch
  /// can be re-armed: when the server starts again, when the hours or the switch move, and
  /// when a client asks for a window or withdraws one.
  /// Sparkle installs it on quit regardless (`SPUUpdaterDelegate.h`: "In either case Sparkle
  /// will always attempt to install the update when the app terminates"), so disarming the
  /// relaunch never loses the update.
  @ObservationIgnored private var pendingInstall: (item: SUAppcastItem, handler: () -> Void)?

  /// The cached settings; see the header for why the feed is not awaited.
  @ObservationIgnored private var feedURL = UpdateFeed.defaultURL
  @ObservationIgnored private var checksAutomatically = false
  @ObservationIgnored private var installsAutomatically = false
  @ObservationIgnored private var installHour = 3
  @ObservationIgnored private var installEndHour = 6
  @ObservationIgnored private var receivesBetas = false

  /// The window a client asked for through `POST /api/v2/server/update/schedule`, as it
  /// asked for it. Holds the relaunch instead of the automatic hours, for the update it was
  /// asked for. Outlives a server stop, like the download it belongs to, and is gone when
  /// the app relaunches: by then the update it was for is installed.
  private(set) var requestedInstallWindow: DateInterval?

  /// Set by `beginUpdate(to:)` and consumed by the first `willInstallUpdateOnQuit` Sparkle
  /// offers. Cleared on any end to the cycle, so a remote request that finds nothing does
  /// not silently install the NEXT release found by a scheduled check.
  ///
  /// With `requestedInstallWindow` set, the handler is taken and held for the window rather
  /// than run: the client asked for a download now and a relaunch later.
  @ObservationIgnored private var remoteInstallRequested = false

  /// Clients blocked in `POST /server/update/install?wait=true`, waiting for the download.
  ///
  /// Sparkle reports progress only through its delegate, so the wait is a continuation each
  /// callback can finish: `willInstallUpdateOnQuit` means the bytes are on disk,
  /// `failedToDownloadUpdate` and `didAbortWithError` mean they are not, and the handler's
  /// own deadline covers a cycle that reports neither. A list rather than one, because two
  /// clients may ask at once and each is owed an answer.
  @ObservationIgnored private var downloadWaiters: [OnceContinuation<UpdateDownloadOutcome>] = []
  /// How the current remote request's download ended, once it has. A waiter registers from a
  /// task of its own, so the outcome can land before it is parked; it reads this instead of
  /// waiting out the deadline for a callback that has already been.
  @ObservationIgnored private var settledDownload: UpdateDownloadOutcome?

  @ObservationIgnored private let logger = Logger(label: "bluebubbles.updater")

  static let watchedKeys: Set<String> = [
    Settings.updateFeedURL.key, Settings.checkForUpdates.key, Settings.autoInstallUpdates.key,
    Settings.autoInstallHour.key, Settings.autoInstallEndHour.key,
    Settings.receiveBetaUpdates.key,
  ]

  /// The one system notification this type posts, so it can be withdrawn by identity.
  /// Nonisolated because the notification delegate reads it off the main actor.
  nonisolated static let notificationIdentifier = "bluebubbles.update-available"
  /// The bell alert for a found release, withdrawn by prefix when the session ends.
  static let availableAlertKey = "updates.available"

  override init() {
    availability = UpdaterPolicy.availability(
      publicKey: Bundle.main.infoDictionary?["SUPublicEDKey"] as? String)
    super.init()
  }

  // MARK: Lifetime

  func attach(_ store: SettingsStore, alerts: AlertCenter, announcer: UpdateAnnouncer) async {
    self.store = store
    self.alerts = alerts
    self.announcer = announcer
    await readSettings(from: store)
    start()
    applySettings()
    armScheduledInstall()

    followTask.run { @MainActor [weak self] in
      for await change in await store.changes() {
        guard !change.changedKeys.isDisjoint(with: Self.watchedKeys) else { continue }
        guard let self else { return }
        await self.readSettings(from: store)
        self.applySettings()
        // A moved window applies to the update already waiting, NOW: the waiting task only
        // re-read it when its sleep ended, up to a day later. Turning the switch off
        // disarms it, unless a client's window is holding it.
        self.armScheduledInstall()
        // A changed feed or schedule takes effect on the next cycle, not the next launch.
        self.controller?.updater.resetUpdateCycleAfterShortDelay()
      }
    }
  }

  func detach() {
    followTask.cancel()
    store = nil
    alerts = nil
    announcer = nil
    // The scheduled RELAUNCH is disarmed; the update is not. A relaunch starts the server,
    // so firing it after somebody stopped the server undid the stop at the install hour.
    // The download stays with Sparkle, which installs it on quit, and `attach` re-arms the
    // relaunch when the server is started again.
    armScheduledInstall()
  }

  /// The menu item, the Home card and the bell's Install Update button. Sparkle shows its
  /// own progress and result, and brings an update it already found back into focus.
  func checkForUpdates() {
    controller?.updater.checkForUpdates()
  }

  // MARK: Setup

  private func start() {
    guard controller == nil else { return }
    switch availability {
    case .unavailable(let reason):
      logger.info("Updater not started", metadata: ["reason": "\(reason)"])
      return
    case .available:
      break
    }
    let controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    do {
      try controller.updater.start()
      self.controller = controller
      // Taps on the update notification come back through this delegate. Nothing else
      // in the app posts local notifications (server notifications go to phones), so
      // there is no other claimant; if one appears, the two have to share a router.
      UNUserNotificationCenter.current().delegate = self
      logger.info("Updater started")
    } catch {
      // A misconfiguration Sparkle found that the policy did not (a feed it cannot parse,
      // a bundle version it cannot compare). Logged, not alerted: nothing the person can
      // do about it from the app, and the menu still has the plain check.
      logger.error("Updater failed to start", metadata: ["error": "\(error)"])
    }
  }

  private func readSettings(from store: SettingsStore) async {
    feedURL = await store.get(Settings.updateFeedURL)
    checksAutomatically = await store.get(Settings.checkForUpdates)
    installsAutomatically = await store.get(Settings.autoInstallUpdates)
    installHour = await store.get(Settings.autoInstallHour)
    installEndHour = await store.get(Settings.autoInstallEndHour)
    receivesBetas = await store.get(Settings.receiveBetaUpdates)
  }

  private func applySettings() {
    guard let updater = controller?.updater else { return }
    updater.automaticallyChecksForUpdates = checksAutomatically
    updater.automaticallyDownloadsUpdates = installsAutomatically
  }

  // MARK: What a person is shown

  private func announceAvailable(_ item: SUAppcastItem) {
    let version = item.displayVersionString
    availableVersion = version

    // The bell. Withdrawn, not merely marked read, when the session ends.
    Task { [alerts] in
      await alerts?.raise(
        UserAlert(
          severity: .info,
          title: "BlueBubbles \(version) is available",
          body: "Install Update shows the release notes and installs it. BlueBubbles "
            + "relaunches afterwards.",
          source: "updates",
          actions: [.installUpdate],
          dedupeKey: Self.availableAlertKey,
          isDurable: false
        ))
    }

    // Notification Center, for someone who has the app in the background. Silent if the
    // permission was never granted; the card and the bell are the definitive surfaces,
    // and this is the auxiliary one, which is how Sparkle describes it too.
    let content = UNMutableNotificationContent()
    content.title = "BlueBubbles \(version) is available"
    content.body = "Open to see the release notes and install it."
    let request = UNNotificationRequest(
      identifier: Self.notificationIdentifier, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { [logger] error in
      if let error {
        logger.debug("Update notification not posted", metadata: ["error": "\(error)"])
      }
    }
  }

  private func withdrawAvailable() {
    availableVersion = nil
    UNUserNotificationCenter.current()
      .removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier])
    Task { [alerts] in
      await alerts?.dismiss(dedupeKeyPrefix: Self.availableAlertKey)
    }
  }

  private enum InstallReason {
    case clientRequested
    case clientScheduled
    case scheduled

    var sentence: String {
      switch self {
      case .clientRequested: "A client asked for the update."
      case .clientScheduled: "A client scheduled the update for this window."
      case .scheduled: "Install Updates Automatically is on, and this is the window it names."
      }
    }
  }

  /// Every write of `installState` goes through here, so every move reaches clients.
  ///
  /// The announcer drops a repeat, so the scheduled wait can report its window on every
  /// wake without telling anyone twice. Detached from a server, there is nobody to tell;
  /// the next attach re-arms the wait, which reports the state again.
  private func setInstallState(_ state: UpdateInstallState?) {
    installState = state
    Task { [announcer] in await announcer?.announce(installState: state) }
  }

  private func announceInstalling(_ item: SUAppcastItem, reason: InstallReason) async {
    let version = item.displayVersionString
    installState = .installing(version: version)
    // Awaited rather than handed to a task: the relaunch follows, and the event has to be
    // on the bus before the process that would put it there is gone.
    await announcer?.announce(installState: .installing(version: version))
    // Durable: it comes back unread after the relaunch, which is the point. Whoever opens
    // the app next finds out why it is on a new version and what decided that.
    await alerts?.raise(
      UserAlert(
        severity: .info,
        title: "Installing BlueBubbles \(version)",
        body: "\(reason.sentence) BlueBubbles relaunches on \(version) in a moment.",
        source: "updates",
        isDurable: true
      ))
  }

  // MARK: The scheduled relaunch

  /// Which window holds the relaunch: the client's, when one asked, or the automatic hours.
  private var installSchedule: InstallSchedule {
    if let requestedInstallWindow { return .requested(requestedInstallWindow) }
    return .daily(DailyInstallHours(startHour: installHour, endHour: installEndHour))
  }

  /// Waits for the window, then for quiet, then relaunches.
  ///
  /// Runs on the main actor between sleeps, so reading the window and asking `isQuiet` are
  /// ordinary calls. The window is re-read on every wake, so changing the setting while a
  /// download waits moves the relaunch without a second download.
  private func scheduleInstall(of item: SUAppcastItem, handler: @escaping () -> Void) {
    pendingInstall = (item, handler)
    armScheduledInstall()
  }

  /// Starts the wait for the window, or stops it.
  ///
  /// Armed only while attached to a running server, with Install Updates Automatically on
  /// or a client's window to keep. Anything else leaves the update to install on quit, as
  /// Sparkle does by default.
  private func armScheduledInstall() {
    scheduledInstall.cancel()
    guard
      UpdaterPolicy.armsScheduledInstall(
        hasDownloadedUpdate: pendingInstall != nil, isServerRunning: store != nil,
        installsAutomatically: installsAutomatically,
        hasRequestedWindow: requestedInstallWindow != nil),
      let (item, handler) = pendingInstall
    else {
      if case .scheduled = installState { setInstallState(nil) }
      return
    }
    let version = item.displayVersionString
    scheduledInstall.run { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let schedule = self.installSchedule
        let window = schedule.window(containingOrAfter: Date())
        self.setInstallState(
          .scheduled(version: version, window: window, origin: schedule.origin))
        let wait = window.start.timeIntervalSinceNow
        if wait > 0 {
          self.logger.info(
            "Update downloaded; relaunch scheduled",
            metadata: [
              "version": "\(version)", "from": "\(window.start)", "until": "\(window.end)",
              "by": "\(schedule.origin.wireValue)",
            ])
          try? await Task.sleep(for: .seconds(wait))
          continue  // Re-read the window: it may have moved while this slept.
        }
        if await self.isQuiet?() ?? true {
          let reason: InstallReason =
            schedule.origin == .requested ? .clientScheduled : .scheduled
          await self.announceInstalling(item, reason: reason)
          handler()
          return
        }
        self.logger.debug(
          "Relaunch held; a scheduled message is due soon",
          metadata: ["version": "\(version)"])
        // No later than the window's end: the next pass then finds the next window rather
        // than relaunching after the hours somebody chose.
        let untilClose = window.end.timeIntervalSinceNow
        try? await Task.sleep(
          for: .seconds(max(1, min(InstallWindow.retryInterval, untilClose))))
      }
    }
  }
}

// MARK: - The API's install

extension SparkleUpdater: UpdateInstalling {

  // `installState` itself witnesses the seam's `async` getter: a synchronous main-actor
  // property satisfies an asynchronous requirement, and the handler's read hops here.

  /// `POST /server/update/install`. The client has already been told which version;
  /// Sparkle re-reads the feed itself, so `item` is what was offered, not what is trusted.
  ///
  /// "Now" beats any window. A download already waiting for one installs at once; one still
  /// under way for a client's window installs when it lands.
  func beginUpdate(to item: AppcastItem) async {
    settledDownload = nil
    if let (pendingItem, handler) = pendingInstall {
      // The bytes are on disk and Sparkle's cycle is parked on the handler, so a fresh check
      // would find it busy and do nothing: the handler IS the install.
      requestedInstallWindow = nil
      settledDownload = .downloaded
      logger.info(
        "Installing the downloaded update now; a client asked",
        metadata: ["version": "\(pendingItem.displayVersionString)"])
      // On the task that was waiting for the window, which `run` cancels first, and off this
      // call, so the request that asked is answered before the relaunch begins.
      scheduledInstall.run { @MainActor [weak self] in
        await self?.announceInstalling(pendingItem, reason: .clientRequested)
        handler()
      }
      return
    }
    guard let updater = controller?.updater else { return }
    guard !updater.sessionInProgress else {
      if remoteInstallRequested {
        // A client's scheduled download is under way: dropping the window turns it into
        // this request, and `willInstallUpdateOnQuit` installs it the moment it lands.
        requestedInstallWindow = nil
        logger.info("Update already downloading for a client; installing when it lands")
        return
      }
      // Someone at the Mac is already in Sparkle's windows. Let them finish.
      logger.info("Update already in progress; not starting another")
      return
    }
    if updater.allowsAutomaticUpdates {
      // Background download, then `willInstallUpdateOnQuit` hands over the relaunch.
      requestedInstallWindow = nil
      remoteInstallRequested = true
      updater.automaticallyDownloadsUpdates = true
      updater.checkForUpdatesInBackground()
    } else {
      // Sparkle will not install silently here (the bundle is not writable by this user,
      // or `SUAllowsAutomaticUpdates` says no), so the best it can do is what the menu item
      // does: put the dialog up for whoever is at the Mac.
      logger.info("Silent install not permitted on this install; showing the updater instead")
      updater.checkForUpdates()
    }
  }

  /// `POST /server/update/install?wait=true`: answer when the download has landed.
  ///
  /// Sparkle's background check hands back no completion, so the wait is the delegate's:
  /// whichever callback fires first decides the outcome. The deadline is the caller's, and a
  /// timeout is reported as a timeout rather than as success — the download is still going,
  /// and telling a client it finished would be the same lie the ignored flag told.
  ///
  /// A second callback (Sparkle sends more than one on some paths) is harmless: the handle
  /// delivers once and `finishDownloadWaiters` empties the list before resuming. A client
  /// that hangs up stops the wait at once rather than holding it to the deadline.
  func awaitDownload(timeout: Duration) async -> UpdateDownloadOutcome {
    // Nothing is downloading and nothing will: `beginUpdate` found Sparkle busy, or put its
    // window up for whoever is at the Mac. Waiting for a callback that cannot come would
    // hold the request open for the whole deadline and then report a timeout.
    // `settledDownload` as well: a download that was already waiting has landed before the
    // wait began, and that is "downloaded", not "nothing downloading".
    guard controller?.updater != nil, remoteInstallRequested || settledDownload != nil else {
      return .notDownloading
    }

    do {
      return try await awaitContinuation(
        timeout: timeout,
        timeoutError: { TimedOut(after: timeout) },
        register: { @MainActor [weak self] handle in self?.parkDownloadWaiter(handle) },
        abandon: { @MainActor [weak self] handle in
          self?.downloadWaiters.removeAll { $0 === handle }
        }
      )
    } catch {
      // The deadline, or the request going away: either way the download did not land
      // inside the wait, and nobody is told otherwise.
      return .timedOut
    }
  }

  /// `POST /api/v2/server/update/schedule`.
  ///
  /// Three starting points. A download already waiting takes the window and re-arms. A
  /// background download already under way (this type's, or the daily one) is told where to
  /// land. Otherwise a background download starts now, reported as `downloading` at once so
  /// the answer to the request says something is happening.
  func scheduleUpdate(
    to item: AppcastItem, within window: DateInterval
  ) async -> UpdateScheduleOutcome {
    if pendingInstall != nil {
      requestedInstallWindow = window
      armScheduledInstall()
      return .scheduled
    }
    // The updater never started: nothing here can install unattended.
    guard let updater = controller?.updater else { return .needsPerson }
    if updater.sessionInProgress {
      // A background download reports `downloading` before it lands; a person in Sparkle's
      // window has a session and no download of ours. Their choice stands.
      guard case .downloading = installState else { return .busy }
      requestedInstallWindow = window
      return .scheduled
    }
    // Sparkle will not install silently here (the bundle is not writable by this user, or
    // `SUAllowsAutomaticUpdates` says no). Its window, which is what an install falls back
    // to, is no way to keep a schedule nobody is there to see.
    guard updater.allowsAutomaticUpdates else { return .needsPerson }
    requestedInstallWindow = window
    remoteInstallRequested = true
    settledDownload = nil
    updater.automaticallyDownloadsUpdates = true
    updater.checkForUpdatesInBackground()
    setInstallState(.downloading(version: item.shortVersion))
    logger.info(
      "Downloading update for a client's window",
      metadata: [
        "version": "\(item.shortVersion)", "from": "\(window.start)", "until": "\(window.end)",
      ])
    return .scheduled
  }

  /// `DELETE /api/v2/server/update/schedule`.
  ///
  /// A download still under way stops being a client's request, so it lands like any
  /// other: held for the automatic hours when that switch is on, installed on quit when it
  /// is not. Left as a request with no window, it would install the moment it landed,
  /// which is the opposite of what cancelling a schedule asks for.
  func cancelScheduledUpdate() async {
    guard requestedInstallWindow != nil else { return }
    requestedInstallWindow = nil
    if let updater = controller?.updater { endRemoteRequest(updater) }
    logger.info("Client's update window withdrawn")
    armScheduledInstall()
  }

  private func parkDownloadWaiter(_ handle: OnceContinuation<UpdateDownloadOutcome>) {
    if let settledDownload {
      handle.resume(returning: settledDownload)
      return
    }
    guard !handle.isResolved else { return }
    downloadWaiters.append(handle)
  }
}

// MARK: - Sparkle's questions about the update

extension SparkleUpdater: SPUUpdaterDelegate {

  func feedURLString(for updater: SPUUpdater) -> String? {
    feedURL
  }

  /// The same set `UpdateHandlers` hands `UpdateChecker`, so the API and Sparkle agree on
  /// whether a beta is "available".
  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    receivesBetas ? [UpdateChecker.betaChannel] : []
  }

  func updater(
    _ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest
  ) {
    setInstallState(.downloading(version: item.displayVersionString))
  }

  func updater(
    _ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error
  ) {
    setInstallState(nil)
    // A window has nothing left to hold. Kept, it would be reported to clients as a
    // schedule for a download that does not exist.
    if pendingInstall == nil { requestedInstallWindow = nil }
    finishDownloadWaiters(with: .failed(DiagnosticText.sentence(for: error)))
    logger.warning(
      "Update download failed",
      metadata: ["version": "\(item.displayVersionString)", "error": "\(error)"])
  }

  /// Sparkle has a download ready and would install it on quit. Three callers want it
  /// sooner, and all take the handler: a client that asked (now), a client that chose a
  /// window, or the automatic hours. Returning true stalls Sparkle's cycle until the handler
  /// runs, which is the point: no week-later nag, no second download.
  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    // The bytes are on disk: that is what this callback means, and it is the answer a
    // `wait=true` client has been holding a connection for.
    finishDownloadWaiters(with: .downloaded)
    if remoteInstallRequested {
      remoteInstallRequested = false
      updater.automaticallyDownloadsUpdates = installsAutomatically
      // A client's window holds it like the automatic hours do, below.
      if requestedInstallWindow == nil {
        logger.info(
          "Installing update and relaunching",
          metadata: ["version": "\(item.displayVersionString)"])
        // The notice first, then the relaunch: the alert has to be written before the
        // process that would write it is gone. `Task` here is main-actor, in order, so the
        // raise is awaited and the handler runs after it.
        Task { @MainActor in
          await announceInstalling(item, reason: .clientRequested)
          immediateInstallHandler()
        }
        return true
      }
    }
    guard installsAutomatically || requestedInstallWindow != nil else { return false }
    scheduleInstall(of: item, handler: immediateInstallHandler)
    return true
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    logger.info("Update available", metadata: ["version": "\(item.displayVersionString)"])
    Task { [announcer] in await announcer?.announce(version: item.displayVersionString) }
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
    endRemoteRequest(updater)
    abandonRequestedWindow()
    finishDownloadWaiters(with: .notDownloading)
    logger.debug("No update found")
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    endRemoteRequest(updater)
    abandonRequestedWindow()
    finishDownloadWaiters(with: .failed(DiagnosticText.sentence(for: error)))
    // A download that was under way is over; a relaunch waiting for its window is not,
    // because Sparkle already has that download and the schedule task still holds it.
    if case .downloading = installState { setInstallState(nil) }
    logger.warning("Update check ended with an error", metadata: ["error": "\(error)"])
  }

  /// Answers everyone waiting on the download, once. The list is emptied first so a second
  /// callback (Sparkle sends more than one on some paths) cannot resume a continuation
  /// twice, which traps.
  fileprivate func finishDownloadWaiters(with outcome: UpdateDownloadOutcome) {
    settledDownload = outcome
    let waiting = downloadWaiters
    downloadWaiters = []
    for waiter in waiting { waiter.resume(returning: outcome) }
  }

  private func endRemoteRequest(_ updater: SPUUpdater) {
    guard remoteInstallRequested else { return }
    remoteInstallRequested = false
    updater.automaticallyDownloadsUpdates = installsAutomatically
  }

  /// A client's window whose download never arrived. Kept, it would be reported as a
  /// schedule for an update that is not coming; a window over a download already on disk
  /// still stands.
  fileprivate func abandonRequestedWindow() {
    guard pendingInstall == nil, requestedInstallWindow != nil else { return }
    requestedInstallWindow = nil
    logger.info("Client's update window dropped; no download arrived for it")
  }
}

// MARK: - Sparkle's questions about showing it

// `@preconcurrency`: this protocol is not annotated for the main actor the way
// `SPUUpdaterDelegate` is, though Sparkle calls both on it. The attribute turns the
// isolation check into a runtime one rather than a compile error.
extension SparkleUpdater: @preconcurrency SPUStandardUserDriverDelegate {

  var supportsGentleScheduledUpdateReminders: Bool { true }

  /// Sparkle proposes immediate focus when the app just launched or the Mac has been
  /// idle, and those are the moments a window is welcome. Any other scheduled find is
  /// ours to show gently.
  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    immediateFocus
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    // Sparkle is putting its own window up (a check the person asked for, or a scheduled
    // one at a good moment). Nothing to add.
    guard !handleShowingUpdate else { return }
    announceAvailable(update)
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    withdrawAvailable()
  }

  func standardUserDriverWillFinishUpdateSession() {
    withdrawAvailable()
    // The session ends when a person dismisses or skips, or an error stops it, or after
    // the scheduled path takes the handler. Only a download that never finished is stale;
    // a scheduled or installing state is still true.
    if case .downloading = installState { setInstallState(nil) }
    // A person in Sparkle's window installed or skipped it themselves; a client's window
    // has nothing to hold. One of ours still downloading keeps it.
    if !remoteInstallRequested { abandonRequestedWindow() }
  }
}

// MARK: - The notification's tap

extension SparkleUpdater: UNUserNotificationCenterDelegate {

  /// Shown even while the app is frontmost. A banner over the window the person is
  /// looking at is still gentler than a modal one.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    // Read off the response here; it is not Sendable, and the strings are all the main
    // actor needs.
    let identifier = response.notification.request.identifier
    let action = response.actionIdentifier
    guard identifier == Self.notificationIdentifier,
      action == UNNotificationDefaultActionIdentifier
    else { return }
    await MainActor.run { checkForUpdates() }
  }
}
