//  UpdatesModel
//  The update check the menu item and the automatic timer share.

import BBSettings
import BBUpdates
import Foundation
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
  private var timer: Task<Void, Never>?

  func attach(_ store: SettingsStore) {
    self.store = store
  }

  func detach() {
    timer?.cancel()
    timer = nil
    store = nil
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
          await self.check()
        }
        try? await Task.sleep(for: Self.checkInterval)
      }
    }
  }

  func check() async {
    // Routed through the same checker the API uses, so the menu item and
    // GET /server/update/check can never disagree about whether an update exists.
    guard let store else { return }
    state = .checking
    do {
      let checker = UpdateChecker(
        feedURL: await store.get(Settings.updateFeedURL),
        currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
          as? String ?? "0.0.0-dev"
      )
      let result = try await checker.check()
      state =
        result.isAvailable
        ? .available(result.item?.shortVersion ?? "?")
        : .upToDate
    } catch {
      state = .failed(String(describing: error))
    }
  }
}
