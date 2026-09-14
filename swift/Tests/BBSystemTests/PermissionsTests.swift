//  PermissionsTests
//  Permission detection, gating, and the change reporting that makes it useful.
//
//  The Full Disk Access probe is the one worth dwelling on. Today's check shells out to
//  `defaults read com.apple.universalaccessAuthWarning.plist` and string-matches the output:
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
  /// absence is a deliberate outcome, not an oversight: one fewer alarming permission in
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
    // And it cannot be prompted for; there is no API to ask.
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

  /// A permission revoked after setup (which happens on OS upgrades) must be reported at
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

/// Counts how many times the monitor loop actually probed.
private actor CountingProbe: PermissionProbing {
  private(set) var checks = 0

  func fullDiskAccess() async -> PermissionStatus {
    checks += 1
    return .granted
  }
  func automation(bundleIdentifier: String) async -> PermissionStatus { .granted }
  func contacts() async -> PermissionStatus { .granted }
  func notifications() async -> PermissionStatus { .granted }
  func systemIntegrityProtectionDisabled() async -> PermissionStatus { .denied }
}

/// The monitor loop's cadence, which is most of this process's idle wakeups.
///
/// A tick is 0.8ms of real work — chat.db opened and read, a half-megabyte-stack thread
/// spawned for an XPC round trip to `tccd`, a `dlopen` — and it used to run every two
/// seconds forever, headless included, where nothing observes the answer. The fast cadence
/// now costs that only while a page displaying the answer is on screen AND the app is
/// frontmost — the only time the user can have just changed a setting, switched back, and be
/// looking at somewhere the change would show.
///
/// Timing here is deliberately loose in the direction that matters: the idle assertion has
/// to span several of the OLD interval's ticks to mean anything, and the live assertion only
/// claims "promptly", not a millisecond count.
@Suite("Permission probe cadence")
struct PermissionCadenceTests {

  @Test("A headless service, which never reports foreground, takes the idle cadence")
  func defaultsToIdle() async {
    let service = PermissionsService(probe: CountingProbe())
    #expect(await service.refreshInterval == PermissionsService.idleRefreshInterval)
    // Non-vacuous only if the two differ; if someone collapses them this test says so
    // rather than passing for the wrong reason.
    #expect(PermissionsService.idleRefreshInterval > PermissionsService.liveRefreshInterval)
  }

  @Test("Frontmost with a page on screen picks the live cadence, and either one leaving gives it back")
  func foregroundAndWatchedSelectsLive() async {
    let service = PermissionsService(probe: CountingProbe())
    await service.setForeground(true)
    await service.setWatching(true)
    #expect(await service.refreshInterval == PermissionsService.liveRefreshInterval)

    await service.setForeground(false)
    #expect(await service.refreshInterval == PermissionsService.idleRefreshInterval)
    await service.setForeground(true)
    #expect(await service.refreshInterval == PermissionsService.liveRefreshInterval)

    await service.setWatching(false)
    #expect(await service.refreshInterval == PermissionsService.idleRefreshInterval)
  }

  /// The regression this whole change exists for.
  ///
  /// The dashboard, the log viewer and every settings tab that is not the permissions one
  /// hold the app frontmost while displaying no permission status whatsoever. Each of them
  /// used to cost a probe every two seconds.
  @Test("Frontmost on a page that shows no permissions stays on the idle cadence")
  func foregroundAloneIsNotEnough() async {
    let service = PermissionsService(probe: CountingProbe())
    await service.setForeground(true)
    #expect(await service.refreshInterval == PermissionsService.idleRefreshInterval)
  }

  /// The mirror of it: a permissions page in a window the user has switched away from.
  @Test("A page on screen in a backgrounded app stays on the idle cadence")
  func watchedAloneIsNotEnough() async {
    let service = PermissionsService(probe: CountingProbe())
    await service.setWatching(true)
    #expect(await service.refreshInterval == PermissionsService.idleRefreshInterval)
  }

  @Test("A backgrounded monitor does not re-probe on the old two-second cadence")
  func idleLoopDoesNotTick() async throws {
    let probe = CountingProbe()
    let service = PermissionsService(probe: probe)
    await service.startMonitoring()
    defer { Task { await service.stopMonitoring() } }

    // Long enough to have spanned several ticks of the interval this replaced.
    try await Task.sleep(for: .milliseconds(2_200))
    let checks = await probe.checks
    // One: the check the loop runs before its first sleep. The old cadence would have
    // managed at least two more in this window.
    #expect(checks == 1, "idle monitor probed \(checks) times in 2.2s")
  }

  @Test("Entering the live cadence re-checks at once rather than waiting out the idle sleep")
  func goingLiveRechecksImmediately() async throws {
    let probe = CountingProbe()
    let service = PermissionsService(probe: probe)
    await service.setWatching(true)
    await service.startMonitoring()
    defer { Task { await service.stopMonitoring() } }

    try await Task.sleep(for: .milliseconds(200))
    let before = await probe.checks
    await service.setForeground(true)
    try await Task.sleep(for: .milliseconds(200))
    let after = await probe.checks
    // Without the restart this would have waited out a sixty-second sleep, which is the
    // whole reason the idle interval is safe to make this long.
    #expect(after > before, "went live and did not re-check (\(before) -> \(after))")
  }

  /// The other order, which is the one the app actually takes: the user is already in a
  /// frontmost app and navigates TO the permissions page.
  @Test("Opening the page while frontmost re-checks at once too")
  func watchingRechecksImmediately() async throws {
    let probe = CountingProbe()
    let service = PermissionsService(probe: probe)
    await service.setForeground(true)
    await service.startMonitoring()
    defer { Task { await service.stopMonitoring() } }

    try await Task.sleep(for: .milliseconds(200))
    let before = await probe.checks
    await service.setWatching(true)
    try await Task.sleep(for: .milliseconds(200))
    let after = await probe.checks
    #expect(after > before, "page opened and did not re-check (\(before) -> \(after))")
  }

  /// Leaving the live cadence must not restart the loop.
  ///
  /// A restart probes before its first sleep, so a `setWatching(false)` that went through
  /// `stopMonitoring`/`startMonitoring` would spend a full tick on the way OUT — paying for
  /// the answer at the one moment nothing is left to render it.
  @Test("Closing the page does not spend a probe on the way out")
  func leavingLiveDoesNotRecheck() async throws {
    let probe = CountingProbe()
    let service = PermissionsService(probe: probe)
    await service.setForeground(true)
    await service.setWatching(true)
    await service.startMonitoring()
    defer { Task { await service.stopMonitoring() } }

    try await Task.sleep(for: .milliseconds(200))
    let before = await probe.checks
    await service.setWatching(false)
    let after = await probe.checks
    #expect(after == before, "closing the page probed (\(before) -> \(after))")
  }
}
