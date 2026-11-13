//  PermissionGrantTests
//  From a probe answering differently to a service running: the monitor, the gate and the read
//  path.
//
//  **The read path is the part a unit test of the registry cannot see.** `AppContext` held
//  `chat.db` in `let`s set at composition, so a server that started without Full Disk Access
//  had no database for the life of the process. Starting a service on a grant would have swapped
//  "inactive, requires a permission" for "failed, chat.db is not readable" and an alert, with
//  the permission granted.
//
//  The probe is a stand-in throughout. No test can make a real TCC grant, and whether macOS
//  applies one to a running process is something only a real Mac can say.

import BBBuiltIns
import BBContacts
import BBCore
import BBDiagnostics
import BBIMessage
import BBInterfaces
import BBServiceKit
import BBSettings
import BBSystem
import BBTestSupport
import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

/// Answers what the test says macOS would.
private actor FlippableProbe: PermissionProbing {
  var fullDisk: PermissionStatus = .denied
  var contactsStatus: PermissionStatus = .notDetermined

  func set(fullDisk: PermissionStatus) { self.fullDisk = fullDisk }
  func set(contacts: PermissionStatus) { self.contactsStatus = contacts }

  func fullDiskAccess() async -> PermissionStatus { fullDisk }
  func automation(bundleIdentifier: String) async -> PermissionStatus { .granted }
  func contacts() async -> PermissionStatus { contactsStatus }
  func notifications() async -> PermissionStatus { .granted }
  func systemIntegrityConfiguration() async -> SIPConfiguration? { .fullyEnabled }
}

private actor GrantLog {
  private(set) var reported: [Set<PermissionID>] = []
  func record(_ permissions: Set<PermissionID>) { reported.append(permissions) }
}

private struct MonitorHost: PermissionsProviding, AlertProviding, LoggerProviding,
  HealthChangeReporting, PermissionGrantRouting
{
  let permissions: PermissionsService
  let alerts: AlertCenter
  let logger = Logger(label: "bluebubbles.test.permission-grants")
  let log: GrantLog

  func serviceHealthDidChange(_ id: ServiceIdentifier) async {}
  func permissionsGranted(_ permissions: Set<PermissionID>) async {
    await log.record(permissions)
  }
}

@Suite("What counts as a grant")
struct PermissionGrantDecisionTests {

  @Test("Anything becoming granted is a grant, whatever it was")
  func becomingGranted() {
    for previous in [PermissionStatus.denied, .notDetermined, .restricted, .unknown] {
      #expect(
        PermissionsMonitorService.granted(
          from: [.fullDiskAccess: previous], to: [.fullDiskAccess: .granted])
          == [.fullDiskAccess])
    }
  }

  /// The check at start covers what was granted before it; a service starting then read the
  /// permission itself. Reporting every granted permission on the first broadcast would be
  /// one redundant pass over the address book per launch.
  @Test("A standing grant and a first reading are not grants")
  func standingIsNot() {
    #expect(
      PermissionsMonitorService.granted(
        from: [.contacts: .granted], to: [.contacts: .granted]
      ).isEmpty)
    #expect(PermissionsMonitorService.granted(from: [:], to: [.contacts: .granted]).isEmpty)
  }

  @Test("A refusal answers the question, and a probe that could not run does not")
  func answered() {
    #expect(
      PermissionsMonitorService.answered(
        from: [.contacts: .notDetermined], to: [.contacts: .denied])
        == [.contacts])
    #expect(
      PermissionsMonitorService.answered(
        from: [.contacts: .notDetermined], to: [.contacts: .unknown]
      ).isEmpty)
    #expect(
      PermissionsMonitorService.answered(from: [.contacts: .denied], to: [.contacts: .granted])
        .isEmpty)
  }
}

@Suite("The monitor reports grants", .serialized)
struct PermissionMonitorGrantTests {

  private func monitor(
    probe: FlippableProbe
  ) -> (PermissionsMonitorService, PermissionsService, AlertCenter, GrantLog) {
    let permissions = PermissionsService(probe: probe)
    let alerts = AlertCenter()
    let log = GrantLog()
    let service = PermissionsMonitorService(
      host: MonitorHost(permissions: permissions, alerts: alerts, log: log))
    return (service, permissions, alerts, log)
  }

  @Test("A probe that starts answering granted reaches the router", .timeLimit(.minutes(1)))
  func grantReachesTheRouter() async throws {
    let probe = FlippableProbe()
    let (service, permissions, _, log) = monitor(probe: probe)
    try await service.start()
    #expect(await log.reported.isEmpty, "nothing has been granted yet")

    await probe.set(fullDisk: .granted)
    await permissions.checkAll()

    try await waitUntil("the grant to be routed", timeout: .seconds(5)) {
      await log.reported.contains([.fullDiskAccess])
    }
    #expect(await log.reported.count == 1, "the broadcast after routing reported it again")
    await service.stop()
  }

  /// This is what spares a person waiting out the idle cadence for the address book they just
  /// handed over.
  @Test("Answering a prompt is reported at once, with no tick", .timeLimit(.minutes(1)))
  func requestBroadcasts() async throws {
    let probe = FlippableProbe()
    let (service, permissions, _, log) = monitor(probe: probe)
    try await service.start()
    // `start` also runs the monitor's loop; the idle sleep is a minute, so anything inside
    // this test's time limit came from the request.
    await probe.set(contacts: .granted)
    await permissions.request(.contacts)

    try await waitUntil("the grant to be routed", timeout: .seconds(5)) {
      await log.reported.contains([.contacts])
    }
    await service.stop()
  }

  @Test("A notice that a permission is missing goes when it is granted", .timeLimit(.minutes(1)))
  func noticesAreWithdrawn() async throws {
    let probe = FlippableProbe()
    let (service, permissions, alerts, log) = monitor(probe: probe)
    try await service.start()
    await alerts.raise(UnansweredContacts.notice)
    #expect(await alerts.all().count == 1)

    await probe.set(contacts: .granted)
    await permissions.checkAll()

    try await waitUntil("the grant to be routed", timeout: .seconds(5)) {
      await !log.reported.isEmpty
    }
    #expect(await alerts.all().isEmpty, "it went on saying Contacts had not been asked for")
    await service.stop()
  }

  @Test("Declining withdraws the notice too, and reports no grant", .timeLimit(.minutes(1)))
  func decliningWithdraws() async throws {
    let probe = FlippableProbe()
    let (service, permissions, alerts, log) = monitor(probe: probe)
    try await service.start()
    await alerts.raise(UnansweredContacts.notice)

    await probe.set(contacts: .denied)
    await permissions.checkAll()

    try await waitUntil("the notice to go", timeout: .seconds(5)) {
      await alerts.all().isEmpty
    }
    #expect(await log.reported.isEmpty)
    await service.stop()
  }
}

@Suite("When Contacts is asked for")
struct UnansweredContactsTests {

  /// The fresh install this finding came from. The step with the button is still ahead, so asking
  /// now is the dialog arriving before anything has been said.
  @Test("A window with setup still to come leaves it to the onboarding step")
  func freshInstall() {
    #expect(
      UnansweredContacts.onStart(hasWindow: true, isOnboardingComplete: false)
        == .leaveToOnboarding)
  }

  @Test("A window past setup is told, not interrupted")
  func pastSetup() {
    #expect(UnansweredContacts.onStart(hasWindow: true, isOnboardingComplete: true) == .notify)
  }

  /// `onboarding_complete` is false on a headless install that never opened the app, and that
  /// walkthrough can never appear there. Reading it first would wait for it for ever.
  @Test("No window is asked at start, whatever the setup flag says")
  func noWindow() {
    #expect(UnansweredContacts.onStart(hasWindow: false, isOnboardingComplete: false) == .ask)
    #expect(UnansweredContacts.onStart(hasWindow: false, isOnboardingComplete: true) == .ask)
  }

  @Test("The notice leads to the page with the button, and can be withdrawn")
  func noticeLeadsSomewhere() {
    #expect(UnansweredContacts.notice.actions == [.openSettings(.permissions)])
    #expect(
      PermissionNotice.Key.missing(.contacts).contains(UnansweredContacts.notice.dedupeKey ?? ""))
  }
}

/// A probe answering with whatever the Mac would, and a prompt it can count.
private actor RecordingPromptProbe: PermissionProbing {
  var status: PermissionStatus
  private(set) var prompts = 0
  init(status: PermissionStatus) { self.status = status }

  func fullDiskAccess() async -> PermissionStatus { .granted }
  func automation(bundleIdentifier: String) async -> PermissionStatus { .granted }
  func contacts() async -> PermissionStatus { status }
  func notifications() async -> PermissionStatus { .granted }
  func systemIntegrityConfiguration() async -> SIPConfiguration? { .fullyEnabled }
  func requestAccess(to id: PermissionID, bundleIdentifier: String) async -> PermissionStatus? {
    prompts += 1
    status = .granted
    return status
  }
}

@Suite("Asking only if nobody has")
struct RequestIfNeverAskedTests {

  @Test("A permission never asked for is asked for")
  func neverAsked() async {
    let probe = RecordingPromptProbe(status: .notDetermined)
    await PermissionsService(probe: probe).requestIfNeverAsked(.contacts)
    #expect(await probe.prompts == 1)
  }

  @Test("One already answered is not", arguments: [PermissionStatus.granted, .denied, .restricted])
  func answered(status: PermissionStatus) async {
    let probe = RecordingPromptProbe(status: status)
    await PermissionsService(probe: probe).requestIfNeverAsked(.contacts)
    #expect(await probe.prompts == 0)
  }

  @Test("A prompt started at launch is stopped with the monitoring", .timeLimit(.minutes(1)))
  func beginAskingIsOwned() async throws {
    let probe = RecordingPromptProbe(status: .notDetermined)
    let service = PermissionsService(probe: probe)
    await service.beginAskingIfNeverAsked(.contacts)
    try await waitUntil("the prompt", timeout: .seconds(5)) { await probe.prompts == 1 }
    await service.stopMonitoring()
  }
}

/// The watcher's declared dependency, without the real monitor: that one runs the real probes,
/// and this test is answering for them.
private actor PermissionsStandIn: Service {
  static let manifest = BuiltInManifests.permissions
  init(host: AppContext) {}
  func start() async throws {}
  func stop() async {}
  var health: ServiceHealth { get async { .running } }
}

@Suite("Full Disk Access arriving while the server runs", .serialized)
struct ReadPathOpeningTests {

  private func emptyReadPath() throws -> ServerComposition.ReadPath {
    ServerComposition.ReadPath(
      database: nil,
      profile: InterfaceFixtures.emptyProfile,
      messages: try InterfaceFixtures.repository(),
      serializer: InterfaceFixtures.serializer,
      searchIndex: SearchIndexStore()
    )
  }

  @Test("The gate opens the database for Full Disk Access, only when it is granted")
  func gateOpens() async {
    let opens = Locked(0)
    let granted = Locked(false)
    let gate = ServerComposition.permissionGate(
      check: { _ in granted.withLock { $0 } },
      openReadPath: { opens.withLock { $0 += 1 } }
    )

    #expect(await gate(.fullDiskAccess) == false)
    #expect(opens.withLock { $0 } == 0, "opened a database it had just been refused")

    granted.withLock { $0 = true }
    #expect(await gate(.contacts))
    #expect(opens.withLock { $0 } == 0, "Contacts has nothing to do with chat.db")

    #expect(await gate(.fullDiskAccess))
    #expect(opens.withLock { $0 } == 1)
  }

  @Test("A context with no read path gets one, and everything reading it sees it")
  func contextOpens() async throws {
    let readPath = try emptyReadPath()
    let context = try await AppContextFixture.make(openReadPath: { readPath })
    #expect(!context.hasMessageAccess)
    #expect(await context.interfaces() == nil)

    await context.openReadPathIfNeeded()

    #expect(context.hasMessageAccess)
    #expect(context.serializer != nil)
    #expect(await context.interfaces() != nil, "the bundle stayed nil after the database opened")
  }

  @Test("One that will not open leaves the context as it was, to try again")
  func openFailure() async throws {
    let attempts = Locked(0)
    let context = try await AppContextFixture.make(openReadPath: {
      attempts.withLock { $0 += 1 }
      return ServerComposition.ReadPath(searchIndex: SearchIndexStore())
    })

    await context.openReadPathIfNeeded()
    #expect(!context.hasMessageAccess)
    await context.openReadPathIfNeeded()
    #expect(attempts.withLock { $0 } == 2)
  }

  @Test("A context that has one does not open another")
  func alreadyOpen() async throws {
    let attempts = Locked(0)
    let context = try await AppContextFixture.make(
      withMessageAccess: true,
      openReadPath: {
        attempts.withLock { $0 += 1 }
        return ServerComposition.ReadPath(searchIndex: SearchIndexStore())
      })

    await context.openReadPathIfNeeded()
    #expect(attempts.withLock { $0 } == 0)
    #expect(context.hasMessageAccess)
  }

  /// The whole chain, on the real watcher, which throws "chat.db is not readable" without a
  /// repository. A registry gate that said yes with no database behind it fails this.
  @Test("The message watcher starts on a grant, with a database behind it")
  func watcherRecovers() async throws {
    let readPath = try emptyReadPath()
    let context = try await AppContextFixture.make(openReadPath: { readPath })
    let granted = Locked(false)
    let registry = ServiceRegistry<AppContext>(
      host: context,
      permissionCheck: ServerComposition.permissionGate(
        check: { _ in granted.withLock { $0 } },
        openReadPath: { await context.openReadPathIfNeeded() }
      ),
      permissionTitle: { PermissionsService.title(for: $0) }
    )
    await registry.register(PermissionsStandIn.self)
    await registry.register(ChangeDetectionService.self) { $0 }
    try await registry.startAll()

    let refused = await registry.health()[ChangeDetectionService.id]
    #expect(
      refused
        == .waiting(
          reason: "needs Full Disk Access so it can watch your message database for new and "
            + "changed messages", on: .permission))

    granted.withLock { $0 = true }
    await registry.permissionsGranted([.fullDiskAccess])

    #expect(context.hasMessageAccess)
    let health = await registry.health()[ChangeDetectionService.id]
    #expect(health == .running, "it was \(String(describing: health))")
    // A start that threw is stopped and left to its restart policy, with its pump gone.
    let isAlive = await registry.service(ChangeDetectionService.id)?.isAlive
    #expect(isAlive == true, "its start threw")
    await registry.stopAll()
  }

  /// The limit Try Again used to be the only way out of. The grant has landed and the database
  /// still will not open at the first attempt, so the start throws and the restart policy takes
  /// over. Each attempt has to ask the gate again, which is what opens it, and read what the
  /// gate opened, which the instance it reuses cannot have captured. The watcher's own policy
  /// runs, on a clock that skips its sleeps, and the test asserts the backoff it asked for.
  @Test("A database that opens on a retry reaches the watcher, with no Try Again")
  func retryOpensTheDatabase() async throws {
    let readPath = try emptyReadPath()
    let opens = Locked(0)
    let context = try await AppContextFixture.make(openReadPath: {
      let attempt = opens.withLock {
        $0 += 1
        return $0
      }
      return attempt == 1 ? ServerComposition.ReadPath(searchIndex: SearchIndexStore()) : readPath
    })
    let clock = TestClock(skipsSleeps: true)
    let registry = ServiceRegistry<AppContext>(
      host: context,
      permissionCheck: ServerComposition.permissionGate(
        check: { _ in true },
        openReadPath: { await context.openReadPathIfNeeded() }
      ),
      clock: clock
    )
    await registry.register(PermissionsStandIn.self)
    await registry.register(ChangeDetectionService.self) { $0 }
    try await registry.startAll()
    #expect(!context.hasMessageAccess, "the first open was meant to fail")

    try await waitUntil("the retry to bring it up", timeout: .seconds(20)) {
      await registry.service(ChangeDetectionService.id)?.isAlive == true
    }
    #expect(clock.waits.first == .seconds(5), "the watcher's own backoff, \(clock.waits)")
    #expect(context.hasMessageAccess)
    #expect(await registry.health()[ChangeDetectionService.id] == .running)
    await registry.stopAll()
  }
}

@Suite("The grant routing is wired into the server")
struct PermissionGrantWiringTests {

  /// A module is not done until the composition root calls it. Both of these compile if removed.
  @Test("The registry is built with the opening gate and the permission titles")
  func registryUsesTheGate() throws {
    let source = try SourceScanner.family(
      "Sources/BlueBubblesServerCore/Composition/ServerComposition.swift"
    ).map(\.text).joined()
    #expect(source.contains("permissionCheck: permissionGate("))
    #expect(source.contains("permissionTitle: { PermissionsService.title(for: $0) }"))
  }

  @Test("A running server settles the unanswered Contacts question once it is up")
  func startSettlesContacts() throws {
    let source = try SourceScanner.file(
      "Sources/BlueBubblesServerCore/Composition/ServerComposition+RunningServer.swift"
    ).text
    #expect(source.contains("await settleUnansweredContacts()"))
  }
}
