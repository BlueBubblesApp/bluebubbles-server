//  PermissionsModel
//  Live permission state for the Permissions page and onboarding.
//
//  Polled rather than pushed: macOS does not notify on a TCC change, so there is nothing to
//  subscribe to. Two seconds is fast enough to feel immediate when the user tabs back from
//  System Settings.
//
//  A tick is NOT cheap, which the header used to claim: it opens chat.db, spawns a thread
//  for an XPC round trip to `tccd`, and `dlopen`s a framework. So the fast cadence is spent
//  only while a page that DISPLAYS the answer is on screen and the app is frontmost. Those
//  are two different facts and the model carries both: `beginObservingActivation` reports
//  frontmost, and `beginWatching`/`endWatching` report whether anything is rendering status.
//
//  Frontmost alone was the earlier rule and it over-approximated badly — the dashboard, the
//  log viewer and every unrelated settings tab all held the app frontmost while displaying
//  no permission status at all, and each paid a probe every two seconds for it.

import AppKit
import BBServiceKit
import BBSystem
import Foundation
import Observation

@Observable
@MainActor
final class PermissionsModel {

  /// Live: a permission granted in System Settings is reflected without navigating away and
  /// back. Otherwise people grant a permission, see no change, and conclude it did not work.
  private(set) var statuses: [PermissionID: PermissionStatus] = [:]
  private(set) var checkedAt: Date?
  /// The declared permission list, in onboarding order. Empty until a server is attached.
  private(set) var list: [Permission] = []
  private(set) var hasMessageAccess: Bool?

  private var service: PermissionsService?
  private var messageAccess: (@Sendable () async -> Bool)?
  private var pollTask: Task<Void, Never>?
  private var activationTask: Task<Void, Never>?

  /// The views currently displaying permission status, by view identity.
  ///
  /// A set of tokens rather than a counter, because `onAppear` is not guaranteed to fire
  /// exactly once per presentation. A counter that gets an extra increment pins the fast
  /// cadence on for the life of the process with no page on screen; re-inserting a token
  /// the view already owns is a no-op, which is the failure mode this wants.
  private var watchers: Set<UUID> = []

  /// Required permissions currently unmet. Drives the sidebar badge and the banner.
  var unsatisfiedRequiredCount: Int {
    list.filter { permission in
      permission.requirement.isRequired
        && (statuses[permission.id] ?? .notDetermined) != .granted
    }.count
  }

  /// Whether Full Disk Access has been granted since this process started.
  ///
  /// The grant applies at process launch, so a running server that was started without it
  /// still cannot read chat.db; the permission reads as granted while the database stays
  /// shut. Offering a relaunch is the only thing that resolves it, and not saying so is
  /// how "I granted it and nothing happened" happens.
  var needsRelaunch: Bool {
    statuses[.fullDiskAccess] == .granted && hasMessageAccess == false
  }

  func attach(
    _ service: PermissionsService,
    hasMessageAccess: @escaping @Sendable () async -> Bool
  ) {
    self.service = service
    self.messageAccess = hasMessageAccess
    list = service.permissions
    // Observe, do not poll. `PermissionsMonitorService` already runs the probe loop, and a
    // second one here meant every check ran twice, including the automation probe, which
    // spawns a thread to ask TCC and is the one worth not doubling.
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      for await states in await service.stream() {
        if Task.isCancelled { return }
        self?.statuses = states
        self?.checkedAt = Date()
      }
    }
    beginObservingActivation(service)
    // Seeded, because a page can already be on screen when the server finishes starting:
    // the permissions tab left open across a stop/start, or the onboarding step that is
    // showing while the first launch sets itself up.
    pushWatching(to: service)
  }

  /// Registers a view that displays permission status.
  ///
  /// Idempotent per view: the token comes from the view's own `@State`, so the repeat
  /// `onAppear` SwiftUI is entitled to send re-inserts what is already there.
  func beginWatching(_ token: UUID) {
    guard watchers.insert(token).inserted else { return }
    if watchers.count == 1, let service { pushWatching(to: service) }
  }

  func endWatching(_ token: UUID) {
    guard watchers.remove(token) != nil else { return }
    if watchers.isEmpty, let service { pushWatching(to: service) }
  }

  private func pushWatching(to service: PermissionsService) {
    let watched = !watchers.isEmpty
    Task { await service.setWatching(watched) }
  }

  /// Tells the service whether the app is frontmost, which is what picks its probe cadence.
  ///
  /// Seeded with the current state rather than waiting for the first notification, because
  /// the app is usually already active by the time a server finishes starting, and the
  /// first `didBecomeActive` after that could be minutes away.
  private func beginObservingActivation(_ service: PermissionsService) {
    activationTask?.cancel()
    let isActive = NSApplication.shared.isActive
    activationTask = Task {
      await service.setForeground(isActive)
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await _ in NotificationCenter.default.notifications(
            named: NSApplication.didBecomeActiveNotification)
          {
            await service.setForeground(true)
          }
        }
        group.addTask {
          for await _ in NotificationCenter.default.notifications(
            named: NSApplication.willResignActiveNotification)
          {
            await service.setForeground(false)
          }
        }
      }
    }
  }

  func detach() {
    pollTask?.cancel()
    pollTask = nil
    activationTask?.cancel()
    activationTask = nil
    // Told before the reference goes, so a service that outlives this attachment is not
    // left believing a page is on screen. `watchers` itself is KEPT: the views that
    // registered are still mounted, and the next `attach` seeds from them.
    if let service { Task { await service.setWatching(false) } }
    service = nil
    messageAccess = nil
    list = []
  }

  func refresh() async {
    guard let service else { return }
    statuses = await service.checkAll()
    hasMessageAccess = await messageAccess?()
    checkedAt = Date()
  }

  func request(_ id: PermissionID) async {
    await service?.request(id)
  }

  /// Records that setup proceeded without a required permission.
  ///
  /// Kept so a later support conversation can distinguish "was never asked" from "was
  /// asked and chose to continue", which are different problems with different fixes.
  func recordOnboardingSkip(_ ids: [String]) {
    UserDefaults.standard.set(ids, forKey: "onboardingSkippedPermissions")
    UserDefaults.standard.set(Date(), forKey: "onboardingSkippedAt")
  }
}
