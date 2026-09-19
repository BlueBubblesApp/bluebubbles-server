//  SparkleUpdater
//  The app's updater: Sparkle, owned here because installing an update relaunches the
//  application, and only the application can be relaunched.
//
//  Three things reach it. The menu item calls `checkForUpdates`, which runs Sparkle's own
//  windows. The daily schedule is Sparkle's, switched by `check_for_updates`. And
//  `POST /server/update/install` reaches it through `UpdateInstalling`: a client asked for
//  the install and nobody is at the Mac, so that path downloads in the background and takes
//  the install-and-relaunch handler the moment Sparkle offers it, with no dialog.
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
//  - An automatic install relaunches at the hour `auto_install_hour` names, not on quit
//    (a server never quits) and not after a week's nag: `InstallWindow` decides the moment
//    and holds it while a scheduled message is about to go out. Same notices as above.
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

  /// What is happening to an update already found: downloading, waiting for the install
  /// hour, or relaunching. Reported on `GET /server/update/check` through the installer
  /// seam; the sidebar strip draws the last stage.
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
  @ObservationIgnored private var followTask: Task<Void, Never>?

  /// Answers "may the app relaunch right now?" for a scheduled install. Supplied by
  /// `AppModel`, which can see the schedule; `InstallWindow.isQuiet` is the rule. Absent,
  /// the answer is yes: there is nothing to consult.
  @ObservationIgnored var isQuiet: (@MainActor () async -> Bool)?

  /// The scheduled install waiting for its hour, so a second download or a settings change
  /// replaces it rather than racing it.
  @ObservationIgnored private var scheduledInstall: Task<Void, Never>?

  /// The cached settings; see the header for why the feed is not awaited.
  @ObservationIgnored private var feedURL = UpdateFeed.defaultURL
  @ObservationIgnored private var checksAutomatically = false
  @ObservationIgnored private var installsAutomatically = false
  @ObservationIgnored private var installHour = 3
  @ObservationIgnored private var receivesBetas = false

  /// Set by `beginUpdate(to:)` and consumed by the first `willInstallUpdateOnQuit` Sparkle
  /// offers. Cleared on any end to the cycle, so a remote request that finds nothing does
  /// not silently install the NEXT release found by a scheduled check.
  @ObservationIgnored private var remoteInstallRequested = false

  /// Clients blocked in `POST /server/update/install?wait=true`, waiting for the download.
  ///
  /// Sparkle reports progress only through its delegate, so the wait is a continuation each
  /// callback can finish: `willInstallUpdateOnQuit` means the bytes are on disk,
  /// `failedToDownloadUpdate` and `didAbortWithError` mean they are not, and the handler's
  /// own deadline covers a cycle that reports neither. A list rather than one, because two
  /// clients may ask at once and each is owed an answer.
  @ObservationIgnored private var downloadWaiters:
    [CheckedContinuation<UpdateDownloadOutcome, Never>] = []

  @ObservationIgnored private let logger = Logger(label: "bluebubbles.updater")

  static let watchedKeys: Set<String> = [
    Settings.updateFeedURL.key, Settings.checkForUpdates.key, Settings.autoInstallUpdates.key,
    Settings.autoInstallHour.key, Settings.receiveBetaUpdates.key,
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

    followTask?.cancel()
    followTask = Task { [weak self] in
      for await change in await store.changes() {
        guard !change.changedKeys.isDisjoint(with: Self.watchedKeys) else { continue }
        guard let self else { return }
        await self.readSettings(from: store)
        self.applySettings()
        // A changed feed or schedule takes effect on the next cycle, not the next launch.
        self.controller?.updater.resetUpdateCycleAfterShortDelay()
      }
    }
  }

  func detach() {
    followTask?.cancel()
    followTask = nil
    store = nil
    alerts = nil
    announcer = nil
    // A pending scheduled install is NOT cancelled: it belongs to the updater, which
    // outlives the server, and a stopped server is the quietest moment there is.
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
    case scheduled

    var sentence: String {
      switch self {
      case .clientRequested: "A client asked for the update."
      case .scheduled: "Install Updates Automatically is on, and this is the hour it names."
      }
    }
  }

  private func announceInstalling(_ item: SUAppcastItem, reason: InstallReason) async {
    let version = item.displayVersionString
    installState = .installing(version: version)
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

  /// Waits for the install hour, then for quiet, then relaunches.
  ///
  /// Runs on the main actor between sleeps, so reading the hour and asking `isQuiet` are
  /// ordinary calls. The hour is re-read on every wake, so changing the setting while a
  /// download waits moves the relaunch without a second download.
  private func scheduleInstall(of item: SUAppcastItem, handler: @escaping () -> Void) {
    scheduledInstall?.cancel()
    let version = item.displayVersionString
    scheduledInstall = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let opening = InstallWindow.nextOpening(hour: self.installHour, after: Date())
        self.installState = .scheduled(version: version, at: opening)
        let wait = opening.timeIntervalSinceNow
        if wait > 0 {
          self.logger.info(
            "Update downloaded; relaunch scheduled",
            metadata: ["version": "\(version)", "at": "\(opening)"])
          try? await Task.sleep(for: .seconds(wait))
          continue  // Re-read the hour: it may have moved while this slept.
        }
        if await self.isQuiet?() ?? true {
          await self.announceInstalling(item, reason: .scheduled)
          handler()
          return
        }
        self.logger.debug(
          "Relaunch held; a scheduled message is due soon",
          metadata: ["version": "\(version)"])
        try? await Task.sleep(for: .seconds(InstallWindow.retryInterval))
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
  func beginUpdate(to item: AppcastItem) async {
    guard let updater = controller?.updater else { return }
    guard !updater.sessionInProgress else {
      // Someone at the Mac is already in Sparkle's windows. Let them finish.
      logger.info("Update already in progress; not starting another")
      return
    }
    if updater.allowsAutomaticUpdates {
      // Background download, then `willInstallUpdateOnQuit` hands over the relaunch.
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
  /// One continuation and one timer, both on the main actor, so "resume" and "time out"
  /// cannot race: `finishDownloadWaiters` empties the list before resuming, which is what
  /// makes a second callback (Sparkle sends more than one on some paths) harmless rather
  /// than a trap.
  func awaitDownload(timeout: Duration) async -> UpdateDownloadOutcome {
    // Nothing is downloading and nothing will: `beginUpdate` found Sparkle busy, or put its
    // window up for whoever is at the Mac. Waiting for a callback that cannot come would
    // hold the request open for the whole deadline and then report a timeout.
    guard controller?.updater != nil, remoteInstallRequested else { return .notDownloading }

    let deadline = Task { @MainActor [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      self?.finishDownloadWaiters(with: .timedOut)
    }
    defer { deadline.cancel() }

    return await withCheckedContinuation { continuation in
      downloadWaiters.append(continuation)
    }
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
    installState = .downloading(version: item.displayVersionString)
  }

  func updater(
    _ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error
  ) {
    installState = nil
    finishDownloadWaiters(with: .failed(error.localizedDescription))
    logger.warning(
      "Update download failed",
      metadata: ["version": "\(item.displayVersionString)", "error": "\(error)"])
  }

  /// Sparkle has a download ready and would install it on quit. Two callers want it
  /// sooner, and both take the handler: a client that asked (now), or the schedule (at the
  /// hour). Returning true stalls Sparkle's cycle until the handler runs, which is the
  /// point: no week-later nag, no second download.
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
    guard installsAutomatically else { return false }
    scheduleInstall(of: item, handler: immediateInstallHandler)
    return true
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    logger.info("Update available", metadata: ["version": "\(item.displayVersionString)"])
    Task { [announcer] in await announcer?.announce(version: item.displayVersionString) }
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
    endRemoteRequest(updater)
    finishDownloadWaiters(with: .notDownloading)
    logger.debug("No update found")
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    endRemoteRequest(updater)
    finishDownloadWaiters(with: .failed(error.localizedDescription))
    // A download that was under way is over; a relaunch waiting for its hour is not,
    // because Sparkle already has that download and the schedule task still holds it.
    if case .downloading = installState { installState = nil }
    logger.warning("Update check ended with an error", metadata: ["error": "\(error)"])
  }

  /// Answers everyone waiting on the download, once. The list is emptied first so a second
  /// callback (Sparkle sends more than one on some paths) cannot resume a continuation
  /// twice, which traps.
  fileprivate func finishDownloadWaiters(with outcome: UpdateDownloadOutcome) {
    let waiting = downloadWaiters
    downloadWaiters = []
    for continuation in waiting { continuation.resume(returning: outcome) }
  }

  private func endRemoteRequest(_ updater: SPUUpdater) {
    guard remoteInstallRequested else { return }
    remoteInstallRequested = false
    updater.automaticallyDownloadsUpdates = installsAutomatically
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
    if case .downloading = installState { installState = nil }
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
