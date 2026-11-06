//  PermissionGrantRoutingTests
//  A permission being granted reaches the services that declared it, without a relaunch.
//
//  `performStart` records a missing required permission and returns. Nothing came back to it:
//  `applyEnablement` and the settings path re-attempt on their own triggers, and a grant was
//  neither. Someone who granted Full Disk Access after switching Message Search on saw nothing
//  change until the next launch, with the reason only in a log.
//
//  The permission check is injected and flipped here. No test can make a real TCC grant.

import Foundation
import Testing

@testable import BBServiceKit

/// What macOS has granted, as far as a registry under test can tell.
private actor GrantBoard {
  private var granted: Set<PermissionID> = []
  func grant(_ id: PermissionID) { granted.insert(id) }
  func has(_ id: PermissionID) -> Bool { granted.contains(id) }
}

private actor NeedsDiskAccess: RecordingService {
  static var manifest: ServiceManifest {
    .minimal(
      id: "needs-disk",
      permissions: [.init(.fullDiskAccess, .required, purpose: "so it can read the database")]
    )
  }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

private actor NeedsTwoPermissions: RecordingService {
  static var manifest: ServiceManifest {
    .minimal(
      id: "needs-two",
      permissions: [
        .init(.fullDiskAccess, .required, purpose: "so it can read the database"),
        .init(.contacts, .required, purpose: "so it can read names"),
      ]
    )
  }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

/// Runs without Contacts, in a reduced form, and wants to know when that ends.
private actor WorksBetterWithContacts: RecordingService, PermissionRespondingService {
  static var manifest: ServiceManifest {
    .minimal(
      id: "responding",
      permissions: [.init(.contacts, .recommended, purpose: "so it can show names")]
    )
  }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
  func permissionGranted(_ id: PermissionID) async {
    await recorder.record("granted:\(id.rawValue)")
  }
}

/// Declares the same permission, and has nothing to do about it.
private actor IndifferentToContacts: RecordingService {
  static var manifest: ServiceManifest {
    .minimal(
      id: "indifferent",
      permissions: [.init(.contacts, .recommended, purpose: "so it can show names")]
    )
  }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

@Suite("A granted permission reaches the services that declared it", .serialized)
struct PermissionGrantRoutingTests {

  private func registry(
    _ recorder: LifecycleRecorder, _ board: GrantBoard,
    enabled: @escaping @Sendable (ServiceIdentifier) async -> Bool = { _ in true }
  ) -> ServiceRegistry<TestContext> {
    ServiceRegistry(
      host: TestContext(recorder: recorder),
      permissionCheck: { await board.has($0) },
      enablementCheck: enabled
    )
  }

  @Test("A service refused at its gate starts when the permission arrives")
  func refusedServiceStarts() async throws {
    let recorder = LifecycleRecorder()
    let board = GrantBoard()
    let registry = registry(recorder, board)
    await registry.register(NeedsDiskAccess.self)
    try await registry.startAll()
    #expect(await recorder.snapshot().isEmpty)

    await board.grant(.fullDiskAccess)
    await registry.permissionsGranted([.fullDiskAccess])

    #expect(await recorder.snapshot() == ["start:needs-disk"])
    #expect(await registry.health()[NeedsDiskAccess.id] == .running)
    await registry.stopAll()
  }

  /// Not every service: a grant of one permission must not disturb a service that declares
  /// another, least of all by restarting it.
  @Test("A service that does not declare the permission is not touched")
  func undeclaredIsLeftAlone() async throws {
    let recorder = LifecycleRecorder()
    let board = GrantBoard()
    let registry = registry(recorder, board)
    await registry.register(NeedsDiskAccess.self)
    try await registry.startAll()

    await registry.permissionsGranted([.contacts])

    #expect(await recorder.snapshot().isEmpty)
    await registry.stopAll()
  }

  @Test("A service still missing another permission keeps waiting, and says which")
  func stillMissingAnother() async throws {
    let recorder = LifecycleRecorder()
    let board = GrantBoard()
    let registry = registry(recorder, board)
    await registry.register(NeedsTwoPermissions.self)
    try await registry.startAll()

    await board.grant(.fullDiskAccess)
    await registry.permissionsGranted([.fullDiskAccess])

    #expect(await recorder.snapshot().isEmpty)
    #expect(
      await registry.health()[NeedsTwoPermissions.id]
        == .waiting(reason: "needs contacts so it can read names", on: .permission))
    await registry.stopAll()
  }

  /// A grant is a reason to re-ask, not a reason to run: the registry's own checks still
  /// decide, so somebody's switch is not overruled by macOS answering a different question.
  @Test("A service someone switched off stays off")
  func switchedOffStaysOff() async throws {
    let recorder = LifecycleRecorder()
    let board = GrantBoard()
    let registry = registry(recorder, board, enabled: { _ in false })
    await registry.register(NeedsDiskAccess.self)
    try await registry.startAll()

    await board.grant(.fullDiskAccess)
    await registry.permissionsGranted([.fullDiskAccess])

    #expect(await recorder.snapshot().isEmpty)
    #expect(await registry.health()[NeedsDiskAccess.id] == .inactive(reason: "switched off"))
    await registry.stopAll()
  }

  @Test("A running service that asked is told, and is not restarted")
  func runningServiceIsTold() async throws {
    let recorder = LifecycleRecorder()
    let board = GrantBoard()
    let registry = registry(recorder, board)
    await registry.register(WorksBetterWithContacts.self)
    try await registry.startAll()

    await board.grant(.contacts)
    await registry.permissionsGranted([.contacts])

    #expect(await recorder.snapshot() == ["start:responding", "granted:contacts"])
    await registry.stopAll()
  }

  /// `.recommended` gates nothing, so a running service that did not ask has clients attached
  /// and no reason to lose them.
  @Test("A running service that did not ask hears nothing")
  func runningServiceThatDidNotAsk() async throws {
    let recorder = LifecycleRecorder()
    let board = GrantBoard()
    let registry = registry(recorder, board)
    await registry.register(IndifferentToContacts.self)
    try await registry.startAll()

    await board.grant(.contacts)
    await registry.permissionsGranted([.contacts])

    #expect(await recorder.snapshot() == ["start:indifferent"])
    await registry.stopAll()
  }

  /// A second report of the same grant, or one for a service that came up by itself after the
  /// grant, is the ordinary case: the service reads the permission at its gate before the
  /// monitor's next tick reports it.
  @Test("A service already running is not started twice")
  func idempotent() async throws {
    let recorder = LifecycleRecorder()
    let board = GrantBoard()
    await board.grant(.fullDiskAccess)
    let registry = registry(recorder, board)
    await registry.register(NeedsDiskAccess.self)
    try await registry.startAll()

    await registry.permissionsGranted([.fullDiskAccess])
    await registry.permissionsGranted([.fullDiskAccess])

    #expect(await recorder.snapshot() == ["start:needs-disk"])
    await registry.stopAll()
  }

  /// The monitor stops last, so it can still be reporting while everything else has gone. A
  /// service started by that would run on after the server had stopped.
  @Test("A grant reported during a shutdown starts nothing")
  func nothingAfterStopAll() async throws {
    let recorder = LifecycleRecorder()
    let board = GrantBoard()
    let registry = registry(recorder, board)
    await registry.register(NeedsDiskAccess.self)
    try await registry.startAll()
    await registry.stopAll()

    await board.grant(.fullDiskAccess)
    await registry.permissionsGranted([.fullDiskAccess])
    #expect(await recorder.snapshot().isEmpty)

    // And a later start is a start: `restartServices` stops and starts on one registry.
    try await registry.startAll()
    #expect(await recorder.snapshot() == ["start:needs-disk"])
    await registry.stopAll()
  }

  /// Nobody reads "full-disk-access". The sentence is the title and the manifest's own reason.
  @Test("The reason names the permission as a person knows it")
  func reasonReadsAsASentence() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(
      host: TestContext(recorder: recorder),
      permissionCheck: { _ in false },
      permissionTitle: { _ in "Full Disk Access" }
    )
    await registry.register(NeedsDiskAccess.self)
    try await registry.startAll()

    let health = await registry.health()[NeedsDiskAccess.id]
    #expect(
      health
        == .waiting(reason: "needs Full Disk Access so it can read the database", on: .permission))
    await registry.stopAll()
  }
}
