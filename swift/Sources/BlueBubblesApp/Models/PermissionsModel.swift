//  PermissionsModel
//  Live permission state for the Permissions page and onboarding.
//
//  Polled rather than pushed: macOS does not notify on a TCC change, so there is nothing to
//  subscribe to. Two seconds is fast enough to feel immediate when the user tabs back from
//  System Settings, and each check is cheap — the expensive one (Full Disk Access) is an
//  attempted file open.

import BBServiceKit
import BBSystem
import Foundation
import Observation

@Observable
@MainActor
final class PermissionsModel {

  /// The single biggest usability gap in the Electron app: a permission granted in System
  /// Settings was not reflected until the user navigated away and back, so people granted a
  /// permission, saw no change, and concluded it did not work.
  private(set) var statuses: [PermissionID: PermissionStatus] = [:]
  private(set) var checkedAt: Date?
  /// The declared permission list, in onboarding order. Empty until a server is attached.
  private(set) var list: [Permission] = []
  private(set) var hasMessageAccess: Bool?

  private var service: PermissionsService?
  private var messageAccess: (@Sendable () async -> Bool)?
  private var pollTask: Task<Void, Never>?

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
  /// still cannot read chat.db — the permission reads as granted while the database stays
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
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        let states = await service.checkAll()
        await MainActor.run {
          self?.statuses = states
          self?.checkedAt = Date()
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  func detach() {
    pollTask?.cancel()
    pollTask = nil
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
  /// asked and chose to continue" — which are different problems with different fixes.
  func recordOnboardingSkip(_ ids: [String]) {
    UserDefaults.standard.set(ids, forKey: "onboardingSkippedPermissions")
    UserDefaults.standard.set(Date(), forKey: "onboardingSkippedAt")
  }
}
