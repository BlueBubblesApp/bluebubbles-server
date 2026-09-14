//  UpdatesModel
//  The plain feed check, for builds that cannot install.
//
//  On a release build Sparkle owns checking and installing (`SparkleUpdater`) and this is
//  idle. On a build with no signing key it is the whole update story, so what it finds has
//  to reach a person somewhere, and the somewhere is the alert centre: a found release is
//  an alert carrying the download link, a failed check is a warning, and a check someone
//  asked for by hand always answers, even to say "up to date", because a menu item that
//  does nothing visible reads as broken. A scheduled check stays quiet when there is
//  nothing to say.

import BBCore
import BBDiagnostics
import BBInterfaces
import BBSettings
import BBUpdates
import Foundation
import Logging
import Observation

@Observable
@MainActor
final class UpdatesModel {

  enum State: Equatable {
    case idle, checking, upToDate
    case available(String)
    case failed(String)
  }

  private(set) var state: State = .idle

  /// How often an automatic check runs.
  ///
  /// Daily. An appcast is a static file and a server that runs for months should learn about
  /// a release without being restarted, but nothing about this is urgent enough to poll more
  /// often than a person would look.
  static let checkInterval: Duration = .seconds(24 * 60 * 60)

  private var store: SettingsStore?
  private var alerts: AlertCenter?
  private var announcer: UpdateAnnouncer?
  private var timer: Task<Void, Never>?
  private let logger = Logger(label: "bluebubbles.updates")

  func attach(_ store: SettingsStore, alerts: AlertCenter, announcer: UpdateAnnouncer) {
    self.store = store
    self.alerts = alerts
    self.announcer = announcer
  }

  func detach() {
    timer?.cancel()
    timer = nil
    store = nil
    alerts = nil
    announcer = nil
  }

  /// Starts the periodic check, if the user asked for one.
  ///
  /// This is what the automatic-update-check setting controls; without it the toggle
  /// governs nothing and only the "Check for Updates…" menu item does anything. Re-read on
  /// every tick rather than captured, so turning it off stops the next check rather than
  /// needing a restart.
  func beginChecks() {
    timer?.cancel()
    timer = Task { [weak self] in
      // A short settle before the first check: launch is busy, and an update banner is
      // the least urgent thing competing for that moment.
      try? await Task.sleep(for: .seconds(30))
      while !Task.isCancelled {
        guard let self, let store = self.store else { return }
        if await store.get(Settings.checkForUpdates) {
          await self.check(userInitiated: false)
        }
        try? await Task.sleep(for: Self.checkInterval)
      }
    }
  }

  /// The first start after an update says so.
  ///
  /// Off the start path: `AppModel` runs this in its own task after the store is attached,
  /// so an alert centre that is slow to write can never hold the server. The previous
  /// version is read before the current one is recorded, and recorded whatever the answer,
  /// so a fresh install is quiet and the next update is not.
  func noteVersionChange() async {
    guard let store else { return }
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    guard !current.isEmpty else { return }
    let previous = await store.get(Settings.lastRunVersion)
    if let notice = WhatsNew.notice(previous: previous, current: current) {
      await alerts?.raise(
        UserAlert(
          severity: .success,
          title: notice.title,
          body: notice.body,
          source: "updates",
          actions: URL(string: notice.notesURL).map { [.openURL($0)] } ?? [],
          isDurable: true
        ))
    }
    if previous != current {
      do {
        try await store.set(Settings.lastRunVersion, to: current)
      } catch {
        // Not `try?`: a failed write means the same notice next start, which is a nuisance
        // worth one log line rather than a silent repeat.
        logger.warning("Could not record the running version", metadata: ["error": "\(error)"])
      }
    }
  }

  /// - Parameter userInitiated: Whether a person asked (the menu item) or the timer did.
  ///   A person always gets an answer; the timer only speaks when there is news.
  func check(userInitiated: Bool) async {
    // Routed through the same checker the API uses, so the menu item and
    // GET /server/update/check can never disagree about whether an update exists.
    guard let store else { return }
    state = .checking
    let current =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    do {
      let beta = await store.get(Settings.receiveBetaUpdates)
      let checker = UpdateChecker(
        feedURL: await store.get(Settings.updateFeedURL), currentVersion: current,
        allowedChannels: beta ? [UpdateChecker.betaChannel] : [])
      let result = try await checker.check()
      if result.isAvailable, let item = result.item {
        state = .available(item.shortVersion)
        await announcer?.announce(version: item.shortVersion)
        await alerts?.raise(
          UserAlert(
            severity: .info,
            title: "BlueBubbles \(item.shortVersion) is available",
            body: "This build cannot install updates itself. Download the release and "
              + "install it by hand.",
            source: "updates",
            actions: URL(string: item.downloadURL).map { [.openURL($0)] } ?? [],
            dedupeKey: "updates.available",
            isDurable: false
          ))
      } else {
        state = .upToDate
        if userInitiated {
          await alerts?.raise(
            UserAlert(
              severity: .success,
              title: "BlueBubbles is up to date",
              body: "\(current) is the newest release.",
              source: "updates",
              dedupeKey: "updates.up-to-date",
              isDurable: false
            ))
        }
      }
    } catch {
      let sentence = DiagnosticText.sentence(for: error)
      state = .failed(sentence)
      await alerts?.raise(
        UserAlert(
          severity: .warning,
          title: "Could not check for updates",
          body: sentence,
          source: "updates",
          dedupeKey: "updates.failed",
          isDurable: false
        ))
    }
  }
}
