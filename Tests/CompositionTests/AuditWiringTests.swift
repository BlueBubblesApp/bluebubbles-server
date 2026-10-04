//  AuditWiringTests
//  The audit log is connected: the bridges translate, the service arms the recorder the
//  container holds, and the manifest is the one the registry starts.
//
//  Wiring tests rather than behaviour tests, in the shape of `EventDeliveryWiringTests`: the
//  module's own suite covers what a record looks like; what is asserted here is that the
//  things that EMIT reach the thing that RECORDS, through the composition root, because an
//  emitter nobody connected is silence rather than an error.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAudit
import BBAuth
import BBBuiltIns
import BBCore
import BBHTTPAPI
import BBPersistence
import BBServiceKit
import BBSettings
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Audit wiring")
struct AuditWiringTests {

  /// A recorder armed over an in-memory table, and the table to read it back from.
  private func armedRecorder() async throws -> (AuditRecorder, AuditRepository) {
    let repository = AuditRepository(
      database: try AppDatabase.inMemory(contributors: [AuditSchema.self]))
    let recorder = AuditRecorder()
    await recorder.arm(store: repository)
    return (recorder, repository)
  }

  /// Everything stored so far, oldest first.
  private func stored(_ recorder: AuditRecorder, _ repository: AuditRepository) async throws
    -> [AuditEvent]
  {
    // `record` hands off to a task; give those tasks their turn before draining.
    try await Task.sleep(for: .milliseconds(50))
    await recorder.drain()
    return try await repository.page(limit: 100, offset: 0).events.reversed()
  }

  // MARK: - The manifest and the service

  @Test("The audit log is a built-in that ships switched off")
  func manifestShipsOff() {
    #expect(BuiltInManifests.all.contains { $0.id == BuiltInManifests.ID.auditLog })
    #expect(BuiltInManifests.disabledByDefault.contains(BuiltInManifests.ID.auditLog))
    #expect(AuditLogService.manifest.id == BuiltInManifests.ID.auditLog)
    #expect(AuditLogService.manifest.isUserManageable)
  }

  @Test("The service watches every one of its fields, the TLS secrets included")
  func watchesEveryField() {
    let manifest = AuditLogService.manifest
    for field in manifest.fields {
      #expect(
        AuditLogService.watchedSettings.contains(manifest.storageKey(for: field.key)),
        "\(field.key) is not watched; a change to it would not restart the service")
    }
    #expect(manifest.fields.filter(\.isSecret).count == 3, "three PEM fields")
  }

  @Test("The container's recorder is inert until the service arms it, and it records its own run")
  func serviceArmsTheContainerRecorder() async throws {
    let context = try await AppContextFixture.make()
    #expect(await context.auditLog.isArmed == false)
    // The table exists on a fresh database even while nothing is recorded into it.
    #expect(try await context.auditEvents.count() == 0)

    let service = AuditLogService(host: context)
    try await service.start()
    #expect(await context.auditLog.isArmed)
    #expect(await service.health == .running)

    await service.stop()
    #expect(await context.auditLog.isArmed == false)

    let events = try await context.auditEvents.page(limit: 10, offset: 0).events.reversed()
    #expect(events.map(\.kind) == [.recordingStarted, .recordingStopped])
    #expect(events.first?.metadata["retention_days"] == .int(AuditRetentionPolicy.defaultDays))
    #expect(events.first?.metadata["forwarding"] == .string("off"))
    #expect(events.first?.metadata["records_reads"] == .bool(false))
  }

  // MARK: - Requests

  @Test("A state-changing request is always recorded; a read only when asked")
  func requestPolicy() {
    #expect(AuditRequestPolicy.shouldRecord(method: .post, recordsReads: false))
    #expect(AuditRequestPolicy.shouldRecord(method: .delete, recordsReads: false))
    #expect(!AuditRequestPolicy.shouldRecord(method: .get, recordsReads: false))
    #expect(AuditRequestPolicy.shouldRecord(method: .get, recordsReads: true))
  }

  @Test("A refusal is denied, a server error is a failure, and anything under 400 succeeded")
  func requestOutcome() {
    #expect(AuditRequestPolicy.outcome(forStatus: 200) == .success)
    #expect(AuditRequestPolicy.outcome(forStatus: 302) == .success)
    #expect(AuditRequestPolicy.outcome(forStatus: 401) == .denied)
    #expect(AuditRequestPolicy.outcome(forStatus: 403) == .denied)
    #expect(AuditRequestPolicy.outcome(forStatus: 404) == .failure)
    #expect(AuditRequestPolicy.outcome(forStatus: 500) == .failure)
  }

  @Test("A finished request becomes an api.request record with the client as actor")
  func requestBridge() async throws {
    let (recorder, repository) = try await armedRecorder()
    let bridge = AuditRequestBridge(recorder: recorder)
    bridge.requestCompleted(
      RequestAuditRecord(
        requestID: "req-7", method: .post, routeTemplate: "/api/v1/message/text",
        handlerID: HandlerID("message.sendText"), status: 200, duration: .milliseconds(12),
        clientAddress: "203.0.113.9", isAuthenticated: true))
    // A read, with reads off: nothing.
    bridge.requestCompleted(
      RequestAuditRecord(
        requestID: "req-8", method: .get, routeTemplate: "/api/v1/ping",
        handlerID: HandlerID("general.ping"), status: 200, duration: .milliseconds(1),
        clientAddress: "203.0.113.9", isAuthenticated: true))

    let events = try await stored(recorder, repository)
    #expect(events.count == 1)
    let event = try #require(events.first)
    #expect(event.kind == .apiRequest)
    #expect(event.actor == .client(address: "203.0.113.9"))
    #expect(event.requestID == "req-7")
    #expect(event.route == "/api/v1/message/text")
    #expect(event.metadata["status"] == .int(200))
    #expect(event.metadata["handler"] == .string("message.sendText"))
    #expect(event.metadata["duration_ms"] == .int(12))
    #expect(event.metadata["authenticated"] == .bool(true))
  }

  // MARK: - Authentication and access control

  @Test("Each authentication refusal maps to its kind, denied, against the client")
  func authenticationBridge() async throws {
    let (recorder, repository) = try await armedRecorder()
    let bridge = AuditAuthenticationBridge(recorder: recorder)
    bridge.record(
      AuthenticationAuditEvent(
        kind: .credentialRejected(reason: "password_mismatch"), transport: .http,
        clientAddress: "203.0.113.9", route: "/api/v1/ping"))
    bridge.record(
      AuthenticationAuditEvent(
        kind: .credentialMissing, transport: .socket, clientAddress: nil, route: "/socket.io/"))
    bridge.record(
      AuthenticationAuditEvent(
        kind: .blocked, transport: .http, clientAddress: "203.0.113.9", route: "/api/v1/ping"))
    bridge.record(
      AuthenticationAuditEvent(
        kind: .scopeRefused(scope: "admin"), transport: .http, clientAddress: "203.0.113.9",
        route: "/api/v1/server/restart"))

    let events = try await stored(recorder, repository)
    #expect(
      events.map(\.kind) == [
        .credentialRejected, .credentialMissing, .requestBlocked, .scopeRefused,
      ])
    #expect(events.allSatisfy { $0.outcome == .denied })
    #expect(events[0].metadata["reason"] == .string("password_mismatch"))
    #expect(events[0].source == .http)
    #expect(events[1].source == .socket)
    #expect(events[1].actor == .client(address: nil))
    #expect(events[1].subject == nil, "nothing identified the peer, so there is no subject")
    #expect(events[3].metadata["scope"] == .string("admin"))
  }

  @Test("An automatic block is the server's doing; an administered one is the caller's")
  func accessControlBridge() async throws {
    let (recorder, repository) = try await armedRecorder()
    let bridge = AuditAccessControlBridge(recorder: recorder)
    bridge.record(
      .clientBlocked(
        address: "203.0.113.9", reason: "bad", failureCount: 5, offenceCount: 2,
        expiresAt: Date(timeIntervalSince1970: 1_700_000_000)))
    await AuditContext.acting(as: .client(address: "198.51.100.7")) {
      bridge.record(.clientUnblocked(address: "203.0.113.9"))
    }

    let events = try await stored(recorder, repository)
    #expect(events.map(\.kind) == [.clientBlocked, .clientUnblocked])
    #expect(events[0].actor == .system(component: "access-control"))
    #expect(events[0].metadata["expires_at"] == .string("2023-11-14T22:13:20.000Z"))
    #expect(events[0].metadata["offence_count"] == .int(2))
    #expect(events[1].actor == .client(address: "198.51.100.7"))
    #expect(events[1].subject == .client("203.0.113.9"))
  }

  // MARK: - Settings

  @Test("A stored value is recorded with its type, a secret as bullets, unset as null")
  func settingsValues() {
    #expect(AuditSettingsBridge.value(Data("42".utf8), isSecret: false) == .int(42))
    #expect(AuditSettingsBridge.value(Data("\"x\"".utf8), isSecret: false) == .string("x"))
    #expect(AuditSettingsBridge.value(Data("true".utf8), isSecret: false) == .bool(true))
    #expect(AuditSettingsBridge.value(nil, isSecret: false) == .null)
    #expect(AuditSettingsBridge.value(Data("\"hunter2\"".utf8), isSecret: true) == .redacted)
    #expect(AuditSettingsBridge.value(nil, isSecret: true) == .redacted)
  }

  @Test("A change to the service switch is read as which services moved")
  func serviceSwitches() {
    let ntfy = BuiltInManifests.ID.ntfy.rawValue
    let audit = BuiltInManifests.ID.auditLog.rawValue
    let before = Data("\"\(ntfy),\(audit)\"".utf8)
    let after = Data("\"\(ntfy)\"".utf8)
    let moved = AuditSettingsBridge.switched(previous: before, current: after)
    #expect(moved.on == [audit])
    #expect(moved.off.isEmpty)
    let reversed = AuditSettingsBridge.switched(previous: after, current: before)
    #expect(reversed.off == [audit])
    #expect(AuditSettingsBridge.switched(previous: nil, current: nil) == (on: [], off: []))
  }

  @Test("A settings write becomes settings.changed, and the switch adds service.enabled")
  func settingsBridge() async throws {
    let (recorder, repository) = try await armedRecorder()
    let bridge = AuditSettingsBridge(recorder: recorder)
    bridge.settingsDidChange(
      SettingsWriteRecord(
        changes: [
          .init(
            key: Settings.disabledServicesKey, isSecret: false,
            previousJSON: Data("\"\(BuiltInManifests.ID.auditLog.rawValue)\"".utf8),
            currentJSON: Data("\"\"".utf8)),
          .init(
            key: Settings.password.key, isSecret: true, previousJSON: nil, currentJSON: nil),
        ],
        removedKeys: []))
    bridge.settingsDidChange(SettingsWriteRecord(changes: [], removedKeys: ["stale_key"]))

    let events = try await stored(recorder, repository)
    #expect(events.map(\.kind) == [.settingsChanged, .serviceEnabled, .settingsRemoved])
    let changed = events[0]
    #expect(changed.actor == .operator, "a write with no context is the person's")
    #expect(
      changed.metadata["keys"]
        == .array([.string(Settings.disabledServicesKey), .string(Settings.password.key)]))
    guard case .object(let changes)? = changed.metadata["changes"],
      case .object(let password)? = changes[Settings.password.key]
    else {
      Issue.record("the changes object is missing")
      return
    }
    #expect(password["previous"] == .redacted)
    #expect(password["current"] == .redacted)
    #expect(events[1].subject == .service(BuiltInManifests.ID.auditLog.rawValue))
    #expect(events[1].metadata["service_name"] == .string(BuiltInManifests.auditLog.name))
    #expect(events[2].metadata["keys"] == .array([.string("stale_key")]))
  }

  @Test("The settings store reports its writes to the attached observer, with the actor in scope")
  func storeReportsWrites() async throws {
    let (recorder, repository) = try await armedRecorder()
    let database = try AppDatabase.inMemory(contributors: [SettingsSchema.self])
    let store = try await SettingsStore(database: database, secrets: InMemorySecretStore())
    await store.attachAuditObserver(AuditSettingsBridge(recorder: recorder))

    try await AuditContext.acting(as: .system(component: "startup")) {
      try await store.set(Settings.socketPort, to: 1_234)
    }

    let events = try await stored(recorder, repository)
    let event = try #require(events.first)
    #expect(event.kind == .settingsChanged)
    #expect(event.actor == .system(component: "startup"))
    #expect(event.subject == .setting(Settings.socketPort.key))
  }

  // MARK: - Service lifecycle

  @Test("Health snapshots are read as the transitions worth a record")
  func healthTransitions() {
    typealias Transition = AuditLogService.HealthTransition
    #expect(Transition.between(nil, .running) == .started)
    #expect(Transition.between(.stopped, .running) == .started)
    #expect(Transition.between(.starting, .degraded(reason: "x")) == .started)
    #expect(Transition.between(.running, .degraded(reason: "x")) == nil, "still up")
    #expect(Transition.between(.running, .stopped) == .stopped)
    #expect(Transition.between(.degraded(reason: "x"), .inactive(reason: "off")) == .stopped)
    #expect(Transition.between(.stopped, .inactive(reason: "off")) == nil, "never up")
    #expect(Transition.between(.running, .starting) == nil, "in progress")
    #expect(Transition.between(.running, .failed(reason: "boom")) == .failed(reason: "boom"))
    #expect(Transition.between(.failed(reason: "boom"), .failed(reason: "boom")) == nil)
    #expect(
      Transition.between(.failed(reason: "boom"), .failed(reason: "other"))
        == .failed(reason: "other"))
  }
}
