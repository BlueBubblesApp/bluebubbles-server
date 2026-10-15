//  UpdateScheduleTests
//  A client can ask for an update inside a window, see what it asked for, and withdraw it.
//
//  The real installer is Sparkle's delegate (`SparkleUpdater`), which needs a signed release
//  on a live feed to exercise. What is testable here is everything a client observes through
//  `UpdateInterface`: what a schedule request is refused for, what the installer is handed,
//  what the status reports afterwards, and the event that tells every other client.

import BBCore
import BBEvents
import BBInterfaces
import BBSettings
import BBTestSupport
import BBUpdates
import Foundation
import Testing

@Suite("Update schedule")
struct UpdateScheduleTests {

  /// A Sparkle stand-in that keeps a requested window the way the real one does.
  private actor Installer: UpdateInstalling {
    private let outcome: UpdateScheduleOutcome
    private(set) var scheduled: [DateInterval] = []
    private(set) var cancellations = 0
    private var requested: DateInterval?
    private var state: UpdateInstallState?

    init(outcome: UpdateScheduleOutcome = .scheduled) {
      self.outcome = outcome
    }

    func beginUpdate(to item: AppcastItem) async {}
    var installState: UpdateInstallState? { state }
    func awaitDownload(timeout: Duration) async -> UpdateDownloadOutcome { .notDownloading }

    func scheduleUpdate(
      to item: AppcastItem, within window: DateInterval
    ) async -> UpdateScheduleOutcome {
      scheduled.append(window)
      guard outcome == .scheduled else { return outcome }
      requested = window
      state = .downloading(version: item.shortVersion)
      return outcome
    }

    func cancelScheduledUpdate() async {
      cancellations += 1
      requested = nil
    }

    var requestedInstallWindow: DateInterval? { requested }
  }

  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
  }

  private static func date(_ day: Int, _ hour: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
  }

  /// Noon on the 11th, server time.
  private static let now = date(11, 12)

  private static func feed(offering version: String?) -> Data {
    let items = [version].compactMap { $0 }.map { version in
      AppcastItem(
        shortVersion: version,
        version: version,
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        releaseNotesHTML: "<p>Notes</p>",
        downloadURL: "https://example.com/BlueBubbles-\(version).dmg",
        lengthInBytes: 2048,
        edSignature: "sig"
      )
    }
    return Data(Appcast(items: items).xmlString().utf8)
  }

  private static func interface(
    installer: (any UpdateInstalling)?,
    offering version: String? = "2.0.0",
    settings: SettingsStore? = nil,
    events: EventBus = EventBus()
  ) async throws -> UpdateInterface {
    let data = feed(offering: version)
    let store: SettingsStore
    if let settings {
      store = settings
    } else {
      store = try await TestSettings.store()
    }
    return UpdateInterface(
      settings: store,
      installer: installer,
      events: events,
      announcer: UpdateAnnouncer(events: events),
      currentVersion: "1.0.0",
      calendar: calendar,
      fetch: { _ in data }
    )
  }

  // MARK: Scheduling

  @Test("A window is handed to the installer and reported back")
  func scheduled() async throws {
    let installer = Installer()
    let window = DateInterval(start: Self.date(12, 2), end: Self.date(12, 5))
    let status = try await Self.interface(installer: installer)
      .schedule(within: window, now: Self.now)

    #expect(await installer.scheduled == [window])
    #expect(status.requestedWindow == window)
    #expect(status.canInstall)
    // The download is under way; the window is reported beside it, not instead of it.
    #expect(status.check.install == .downloading(version: "2.0.0"))
  }

  @Test("A window that has ended is refused before the installer is asked")
  func pastWindowRefused() async throws {
    let installer = Installer()
    let window = DateInterval(start: Self.date(10, 2), end: Self.date(10, 5))
    await #expect(throws: InterfaceError.self) {
      try await Self.interface(installer: installer).schedule(within: window, now: Self.now)
    }
    #expect(await installer.scheduled.isEmpty)
  }

  /// Milliseconds read as microseconds, or a date typed a year out, is far more likely
  /// than a plan to relaunch next month, and accepting it would leave an update parked
  /// with nothing to show for it.
  @Test("A window more than a week away is refused")
  func distantWindowRefused() async throws {
    let installer = Installer()
    let window = DateInterval(start: Self.date(25, 2), end: Self.date(25, 5))
    await #expect(throws: InterfaceError.self) {
      try await Self.interface(installer: installer).schedule(within: window, now: Self.now)
    }
    #expect(await installer.scheduled.isEmpty)
  }

  /// A window that misses comes round the next day; one longer than a day would overlap
  /// its own repeat.
  @Test("A window longer than a day is refused")
  func longWindowRefused() async throws {
    let installer = Installer()
    let window = DateInterval(start: Self.date(12, 2), end: Self.date(13, 5))
    await #expect(throws: InterfaceError.self) {
      try await Self.interface(installer: installer).schedule(within: window, now: Self.now)
    }
    #expect(await installer.scheduled.isEmpty)
  }

  @Test("A window that has already opened is accepted: it means from now")
  func openWindowAccepted() async throws {
    let installer = Installer()
    let window = DateInterval(start: Self.date(11, 10), end: Self.date(11, 14))
    let status = try await Self.interface(installer: installer)
      .schedule(within: window, now: Self.now)
    #expect(status.requestedWindow == window)
  }

  @Test("Nothing to install is refused, as an install is")
  func upToDate() async throws {
    let installer = Installer()
    let window = DateInterval(start: Self.date(12, 2), end: Self.date(12, 5))
    await #expect(throws: InterfaceError.self) {
      try await Self.interface(installer: installer, offering: nil)
        .schedule(within: window, now: Self.now)
    }
    #expect(await installer.scheduled.isEmpty)
  }

  /// The headless CLI has nothing to relaunch. Accepting a schedule there would tell the
  /// client "tonight" about an install that can never happen.
  @Test("A server with no installer refuses rather than accepting a schedule it cannot keep")
  func noInstaller() async throws {
    let window = DateInterval(start: Self.date(12, 2), end: Self.date(12, 5))
    await #expect(throws: InterfaceError.self) {
      try await Self.interface(installer: nil).schedule(within: window, now: Self.now)
    }
    let status = try await Self.interface(installer: nil).status(now: Self.now)
    #expect(!status.canInstall)
  }

  @Test("An installer that cannot keep the window says so, and nothing is reported scheduled")
  func installerRefuses() async throws {
    for outcome in [UpdateScheduleOutcome.busy, .needsPerson] {
      let installer = Installer(outcome: outcome)
      let window = DateInterval(start: Self.date(12, 2), end: Self.date(12, 5))
      await #expect(throws: InterfaceError.self) {
        try await Self.interface(installer: installer).schedule(within: window, now: Self.now)
      }
      #expect(await installer.requestedInstallWindow == nil)
    }
  }

  // MARK: Cancelling

  @Test("Cancelling withdraws the requested window and reports the status without it")
  func cancelled() async throws {
    let installer = Installer()
    let interface = try await Self.interface(installer: installer)
    let window = DateInterval(start: Self.date(12, 2), end: Self.date(12, 5))
    _ = try await interface.schedule(within: window, now: Self.now)

    let status = try await interface.cancelSchedule(now: Self.now)
    #expect(await installer.cancellations == 1)
    #expect(status.requestedWindow == nil)
  }

  // MARK: The status

  /// The window rolls: a client that opens the page after a missed window sees tomorrow's,
  /// which is when the relaunch will actually be tried.
  @Test("A requested window that has closed is reported at its next occurrence")
  func requestedWindowRolls() async throws {
    let installer = Installer()
    let interface = try await Self.interface(installer: installer)
    let window = DateInterval(start: Self.date(12, 2), end: Self.date(12, 5))
    _ = try await interface.schedule(within: window, now: Self.now)

    let later = try await interface.status(now: Self.date(12, 9))
    #expect(later.requestedWindow == DateInterval(start: Self.date(13, 2), end: Self.date(13, 5)))
  }

  @Test("The automatic hours are reported, in this Mac's time zone, whether or not they are on")
  func automaticHours() async throws {
    let settings = try await TestSettings.store()
    try await settings.set(Settings.autoInstallHour, to: 22)
    try await settings.set(Settings.autoInstallEndHour, to: 5)
    let status = try await Self.interface(installer: Installer(), settings: settings)
      .status(now: Self.now)

    #expect(!status.automatic.isEnabled)
    #expect(status.automatic.hours == DailyInstallHours(startHour: 22, endHour: 5))
    #expect(
      status.automatic.nextWindow == DateInterval(start: Self.date(11, 22), end: Self.date(12, 5)))
    #expect(status.automatic.timeZone.identifier == "America/New_York")

    // Both switches: the automatic install needs the daily check to find the release.
    try await settings.set(Settings.autoInstallUpdates, to: true)
    let installOnly = try await Self.interface(installer: Installer(), settings: settings)
      .status(now: Self.now)
    #expect(!installOnly.automatic.isEnabled)
    try await settings.set(Settings.checkForUpdates, to: true)
    let both = try await Self.interface(installer: Installer(), settings: settings)
      .status(now: Self.now)
    #expect(both.automatic.isEnabled)
  }

  @Test("The wire shape is snake_case with epoch-millisecond dates, release date included")
  func wireShape() async throws {
    let installer = Installer()
    let window = DateInterval(start: Self.date(12, 2), end: Self.date(12, 5))
    let status = try await Self.interface(installer: installer)
      .schedule(within: window, now: Self.now)
    let json = UpdateInterface.serialize(status)

    #expect(json["current_version"] == .string("1.0.0"))
    #expect(json["available"] == .bool(true))
    #expect(json["update"]?["version"] == .string("2.0.0"))
    #expect(json["update"]?["release_date"] == .int64(1_700_000_000_000))
    #expect(json["update"]?["release_notes"] == .string("<p>Notes</p>"))
    #expect(
      json["update"]?["release_notes_url"]
        == .string(ReleasePages.notes(forVersion: "2.0.0")))
    #expect(json["install"]?["state"] == .string("downloading"))
    #expect(json["can_install"] == .bool(true))
    #expect(
      json["requested_window"]?["start"]
        == .int64(window.start.epochMilliseconds(rounded: .toNearestOrAwayFromZero)))
    #expect(json["automatic_install"]?["start_hour"] == .int(3))
    #expect(json["automatic_install"]?["end_hour"] == .int(6))
    #expect(json["automatic_install"]?["time_zone"] == .string("America/New_York"))
    #expect(json["automatic_install"]?["next_window"]?["end"] != nil)
  }

  /// Null, not absent, for the same reason v1's `metadata` is: a strict decoder tells the two
  /// apart, and "there is nothing" is an answer.
  @Test("Nothing available and nothing requested are explicit nulls")
  func explicitNulls() async throws {
    let status = try await Self.interface(installer: Installer(), offering: nil)
      .status(now: Self.now)
    let json = UpdateInterface.serialize(status)
    #expect(json["available"] == .bool(false))
    #expect(json["update"] == .null)
    #expect(json["install"] == .null)
    #expect(json["requested_window"] == .null)
  }

  // MARK: The event

  @Test("Every change of install state reaches clients once, and a repeat is not news")
  func stateChangesAreAnnounced() async throws {
    let events = EventBus()
    let sink = RecordingSink(id: .socket, projection: .full)
    await events.register(sink)
    let announcer = UpdateAnnouncer(events: events)
    let window = DateInterval(start: Self.date(12, 2), end: Self.date(12, 5))
    let scheduled = UpdateInstallState.scheduled(
      version: "2.0.0", window: window, origin: .requested)

    // Nothing pending is what a client assumes already.
    let first = await announcer.announce(installState: nil)
    let downloading = await announcer.announce(installState: .downloading(version: "2.0.0"))
    let waiting = await announcer.announce(installState: scheduled)
    let repeated = await announcer.announce(installState: scheduled)
    let cleared = await announcer.announce(installState: nil)
    #expect([first, downloading, waiting, repeated, cleared] == [false, true, true, false, true])
    await events.settle()

    let names = await sink.names()
    #expect(names == Array(repeating: EventName.serverUpdateStatusChanged, count: 3))
    let payloads = await sink.payloads
    #expect(payloads.first?["install"]?["state"] == .string("downloading"))
    #expect(payloads.dropFirst().first?["install"]?["scheduled_by"] == .string("client"))
    #expect(payloads.last?["install"] == .null)
  }
}
