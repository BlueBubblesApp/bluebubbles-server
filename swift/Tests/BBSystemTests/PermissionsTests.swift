//  PermissionsTests
//  Permission detection, gating, and the change reporting that makes it useful.
//
//  The Full Disk Access probe is the one worth dwelling on. Today's check shells out to
//  `defaults read com.apple.universalaccessAuthWarning.plist` and string-matches the output —
//  a file that has nothing to do with Full Disk Access. The replacement opens `chat.db`,
//  which is the operation the server actually needs, so it cannot be right about the file and
//  wrong about the access.

import BBServiceKit
import Foundation
import Testing

@testable import BBSystem

/// A probe whose answers the test controls.
private actor StubProbe: PermissionProbing {
  var fullDisk: PermissionStatus = .granted
  var automationStatus: PermissionStatus = .granted
  var contactsStatus: PermissionStatus = .granted
  var notificationsStatus: PermissionStatus = .granted
  var sip: PermissionStatus = .denied

  func set(fullDisk: PermissionStatus) { self.fullDisk = fullDisk }
  func set(contacts: PermissionStatus) { self.contactsStatus = contacts }

  func fullDiskAccess() async -> PermissionStatus { fullDisk }
  func automation(bundleIdentifier: String) async -> PermissionStatus { automationStatus }
  func contacts() async -> PermissionStatus { contactsStatus }
  func notifications() async -> PermissionStatus { notificationsStatus }
  func systemIntegrityProtectionDisabled() async -> PermissionStatus { sip }
}

@Suite("Permission descriptors")
struct PermissionDescriptorTests {

  /// Accessibility existed solely for the UI-automation scripts that were dropped. Its
  /// absence is a deliberate outcome, not an oversight — one fewer alarming permission in
  /// onboarding.
  @Test("Accessibility is not requested at all")
  func noAccessibilityPermission() async {
    let ids = PermissionsService().permissions.map(\.id.rawValue)
    #expect(!ids.contains { $0.contains("accessibility") })
  }

  @Test("Every permission carries a user-facing reason")
  func everyPermissionExplainsItself() async {
    for permission in PermissionsService().permissions {
      #expect(!permission.why.isEmpty, "\(permission.id) has no explanation")
      #expect(!permission.title.isEmpty)
    }
  }

  /// Only Full Disk Access is genuinely required. Automation is needed only without the
  /// Private API, and the rest improve things without gating anything.
  @Test("Full Disk Access is the only hard requirement")
  func onlyFullDiskIsRequired() async {
    let required = PermissionsService().permissions
      .filter { $0.requirement.isRequired }
      .map(\.id)
    #expect(required == [.fullDiskAccess])
  }

  /// "Open System Settings and find it" is how users end up in the wrong pane.
  @Test("Permissions that live in System Settings deep-link to their pane")
  func deepLinks() async {
    for permission in PermissionsService().permissions
    where permission.id != .systemIntegrityProtection {
      #expect(permission.settingsPane != nil, "\(permission.id) has no deep link")
    }
    // SIP has none on purpose: it is a Recovery-mode operation with no pane to link to.
    let sip = PermissionsService().permissions
      .first { $0.id == .systemIntegrityProtection }
    #expect(sip?.settingsPane == nil)
  }

  /// The step users most often get half-right: the app has to be added by hand and then
  /// relaunched, and both halves have to be said.
  @Test("Full Disk Access states that it needs a relaunch")
  func fullDiskNeedsRelaunch() async {
    let permission = PermissionsService().permissions
      .first { $0.id == .fullDiskAccess }
    #expect(permission?.requiresRelaunch == true)
    // And it cannot be prompted for — there is no API to ask.
    #expect(permission?.canPrompt == false)
  }
}

@Suite("Permission checking")
struct PermissionCheckingTests {

  @Test("Statuses are read from the probe and cached")
  func checksAndCaches() async {
    let probe = StubProbe()
    let service = PermissionsService(probe: probe)

    #expect(await service.check(.fullDiskAccess) == .granted)
    #expect(await service.status(of: .fullDiskAccess) == .granted)
  }

  @Test("Required permissions gate onboarding")
  func requiredGating() async {
    let probe = StubProbe()
    let service = PermissionsService(probe: probe)

    await service.checkAll()
    #expect(await service.requiredPermissionsSatisfied())

    await probe.set(fullDisk: .denied)
    await service.checkAll()
    #expect(await !service.requiredPermissionsSatisfied())
    #expect(await service.unsatisfiedRequired().map(\.id) == [.fullDiskAccess])
  }

  /// A permission revoked after setup — which happens on OS upgrades — must be reported at
  /// the moment it breaks rather than surfacing later as unexplained failures.
  @Test("A change is reported with both the old and new status")
  func changeReporting() async {
    let recorder = ChangeRecorder()
    let probe = StubProbe()
    let service = PermissionsService(probe: probe) { id, from, to in
      await recorder.record(id: id, from: from, to: to)
    }

    await service.checkAll()
    await probe.set(fullDisk: .denied)
    await service.checkAll()

    let changes = await recorder.changes
    #expect(changes.count == 1)
    #expect(changes.first?.id == .fullDiskAccess)
    #expect(changes.first?.from == .granted)
    #expect(changes.first?.to == .denied)
  }

  /// Re-checking an unchanged permission must not fire the callback, or a live-refreshing
  /// page would raise an alert every two seconds.
  @Test("An unchanged status reports nothing")
  func noChangeNoReport() async {
    let recorder = ChangeRecorder()
    let service = PermissionsService(probe: StubProbe()) { id, from, to in
      await recorder.record(id: id, from: from, to: to)
    }

    await service.checkAll()
    await service.checkAll()
    await service.checkAll()
    #expect(await recorder.changes.isEmpty)
  }

  /// Wired into the registry's gate, so a service whose permission is missing reports a
  /// precise reason instead of failing obscurely at first use.
  @Test("The registry preflight reflects live status")
  func registryPreflight() async {
    let probe = StubProbe()
    let service = PermissionsService(probe: probe)
    let check = await service.permissionCheck()

    #expect(await check(.fullDiskAccess))
    await probe.set(fullDisk: .denied)
    #expect(await !check(.fullDiskAccess))
  }

  /// notDetermined and denied need different advice: one is worth prompting for, the other
  /// needs the user to go to System Settings.
  @Test("notDetermined is distinct from denied")
  func notDeterminedIsDistinct() async {
    let probe = StubProbe()
    await probe.set(contacts: .notDetermined)
    let service = PermissionsService(probe: probe)

    #expect(await service.check(.contacts) == .notDetermined)
    #expect(await service.check(.contacts) != .denied)
  }

  @Test("An unknown permission id reports unknown rather than granted")
  func unknownPermission() async {
    let service = PermissionsService(probe: StubProbe())
    #expect(await service.check(PermissionID("invented")) == .unknown)
  }
}

private actor ChangeRecorder {
  struct Change: Sendable {
    let id: PermissionID
    let from: PermissionStatus
    let to: PermissionStatus
  }
  private(set) var changes: [Change] = []
  func record(id: PermissionID, from: PermissionStatus, to: PermissionStatus) {
    changes.append(Change(id: id, from: from, to: to))
  }
}

@Suite("Full Disk Access detection")
struct FullDiskAccessTests {

  /// The authoritative check: open the file the server actually needs.
  @Test("A readable database reads as granted")
  func readableDatabaseIsGranted() async throws {
    let path = NSTemporaryDirectory() + "bb-fda-\(UUID().uuidString.prefix(8)).db"
    try Data("SQLite format 3\0".utf8).write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }

    let probe = SystemPermissionProbe(chatDatabasePath: path)
    #expect(await probe.fullDiskAccess() == .granted)
  }

  /// No Messages database at all is not a permission problem, and reporting it as one would
  /// send the user to the wrong settings pane.
  @Test("A missing database is unknown, not denied")
  func missingDatabaseIsUnknown() async {
    let probe = SystemPermissionProbe(chatDatabasePath: "/nope/missing.db")
    #expect(await probe.fullDiskAccess() == .unknown)
  }
}
