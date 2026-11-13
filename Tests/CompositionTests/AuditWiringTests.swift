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
import BBLicense
import BBLicensing
import BBPersistence
import BBServiceKit
import BBSettings
import BBTestSupport
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

  /// Everything stored so far, by kind, for a test that recorded one of each.
  ///
  /// By kind rather than by position: `record` hands each event to its own task, so two
  /// recorded in the same millisecond may be stored in either order, and the recorder says
  /// so (`AuditRecorder`'s header). Read by index, a test would pass or fail on scheduling.
  private func storedByKind(_ recorder: AuditRecorder, _ repository: AuditRepository)
    async throws -> [AuditEventKind: AuditEvent]
  {
    let events = try await stored(recorder, repository)
    #expect(Set(events.map(\.kind)).count == events.count, "one record of each kind")
    return Dictionary(events.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
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
    #expect(context.auditLog.isRecording == false)
    // The table exists on a fresh database even while nothing is recorded into it.
    #expect(try await context.auditEvents.count() == 0)

    let service = AuditLogService(host: context)
    try await service.start()
    #expect(context.auditLog.isRecording)
    #expect(await service.health == .running)

    await service.stop()
    #expect(context.auditLog.isRecording == false)

    let events = try await context.auditEvents.page(limit: 10, offset: 0).events.reversed()
    #expect(events.map(\.kind) == [.recordingStarted, .recordingStopped])
    #expect(events.first?.metadata["retention_days"] == .int(AuditRetentionPolicy.defaultDays))
    #expect(events.first?.metadata["forwarding"] == .string("off"))
    #expect(events.first?.metadata["records_reads"] == .bool(false))
  }

  /// A store that refuses records has to reach a person: an alert, and a health that says so.
  /// It used to be one log line, while the service reported itself running and records past
  /// the recorder's cap were being lost.
  @Test("A refusing store raises an alert and degrades health, and recovery clears both")
  func refusingStoreIsReported() async throws {
    let context = try await AppContextFixture.make()
    let service = AuditLogService(host: context)
    try await service.start()
    try context.appDatabase.writeSynchronously { db in
      try db.execute(
        sql: """
          CREATE TRIGGER refuse BEFORE INSERT ON audit_event
          BEGIN SELECT RAISE(ABORT, 'refused'); END
          """)
    }
    context.auditLog.record(AuditEvent(kind: .settingsChanged, summary: "refused"))
    await context.auditLog.drain()

    guard case .degraded(let reason, _) = await service.health else {
      Issue.record("expected degraded health, got \(await service.health)")
      return
    }
    #expect(reason.contains("not being stored"))
    let raised = await context.alerts.all().filter {
      $0.dedupeKey == AuditLogService.storageAlertKey
    }
    #expect(raised.count == 1)
    #expect(raised.first?.severity == .error)

    try context.appDatabase.writeSynchronously { db in
      try db.execute(sql: "DROP TRIGGER refuse")
    }
    // The retry the refusal scheduled, at the first backoff step.
    await context.auditLog.drain()
    #expect(await service.health == .running)
    #expect(
      await context.alerts.all().filter { $0.dedupeKey == AuditLogService.storageAlertKey }.isEmpty)
    await service.stop()
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
    // The subscription gate's answer is a refusal, not a server failure.
    #expect(AuditRequestPolicy.outcome(forStatus: 402) == .denied)
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

    let events = try await storedByKind(recorder, repository)
    #expect(
      Set(events.keys) == [.credentialRejected, .credentialMissing, .requestBlocked, .scopeRefused])
    #expect(events.values.allSatisfy { $0.outcome == .denied })
    #expect(events[.credentialRejected]?.metadata["reason"] == .string("password_mismatch"))
    #expect(events[.credentialRejected]?.source == .http)
    #expect(events[.credentialMissing]?.source == .socket)
    #expect(events[.credentialMissing]?.actor == .client(address: nil))
    #expect(
      events[.credentialMissing]?.subject == nil,
      "nothing identified the peer, so there is no subject")
    #expect(events[.scopeRefused]?.metadata["scope"] == .string("admin"))
    // Every refusal carries its transport; the scope one used to replace it with the scope.
    #expect(events.values.allSatisfy { $0.metadata["transport"] != nil })
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

    let events = try await storedByKind(recorder, repository)
    #expect(Set(events.keys) == [.clientBlocked, .clientUnblocked])
    let blocked = try #require(events[.clientBlocked])
    #expect(blocked.actor == .system(component: "access-control"))
    #expect(blocked.metadata["expires_at"] == .string("2023-11-14T22:13:20.000Z"))
    #expect(blocked.metadata["offence_count"] == .int(2))
    #expect(events[.clientUnblocked]?.actor == .client(address: "198.51.100.7"))
    #expect(events[.clientUnblocked]?.subject == .client("203.0.113.9"))
  }

  // MARK: - Settings

  @Test("A stored value is recorded with its type, a secret as bullets, unset as null")
  func settingsValues() {
    #expect(AuditSettingsBridge.value(Data("42".utf8), isWithheld: false) == .int(42))
    #expect(AuditSettingsBridge.value(Data("\"x\"".utf8), isWithheld: false) == .string("x"))
    #expect(AuditSettingsBridge.value(Data("true".utf8), isWithheld: false) == .bool(true))
    #expect(AuditSettingsBridge.value(nil, isWithheld: false) == .null)
    #expect(AuditSettingsBridge.value(Data("\"hunter2\"".utf8), isWithheld: true) == .redacted)
    #expect(AuditSettingsBridge.value(nil, isWithheld: true) == .redacted)
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

    let events = try await storedByKind(recorder, repository)
    #expect(Set(events.keys) == [.settingsChanged, .serviceEnabled, .settingsRemoved])
    let changed = try #require(events[.settingsChanged])
    #expect(changed.actor == .unattributed, "a write with no context is nobody's")
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
    #expect(events[.serviceEnabled]?.subject == .service(BuiltInManifests.ID.auditLog.rawValue))
    #expect(
      events[.serviceEnabled]?.metadata["service_name"]
        == .string(BuiltInManifests.auditLog.name))
    #expect(events[.settingsRemoved]?.metadata["keys"] == .array([.string("stale_key")]))
  }

  /// The server's public address is published into `server_address` by every connection
  /// method, and the audit record is built to leave this Mac. That it changed is the record;
  /// where the server can now be reached is not.
  @Test("A confidential setting is recorded as changed with both values withheld")
  func confidentialValuesAreWithheld() async throws {
    let (recorder, repository) = try await armedRecorder()
    let bridge = AuditSettingsBridge(recorder: recorder)
    let tunnelHost = BuiltInManifests.cloudflare.storageKey(for: "hostname")
    bridge.settingsDidChange(
      SettingsWriteRecord(
        changes: [
          .init(
            key: Settings.serverAddress.key, isSecret: false, previousJSON: nil,
            currentJSON: Data("\"https://messages.example.com\"".utf8)),
          .init(
            key: tunnelHost, isSecret: false, previousJSON: Data("\"a.example.com\"".utf8),
            currentJSON: Data("\"b.example.com\"".utf8)),
          .init(
            key: Settings.socketPort.key, isSecret: false, previousJSON: Data("1234".utf8),
            currentJSON: Data("1235".utf8)),
        ],
        removedKeys: []))

    let events = try await stored(recorder, repository)
    guard case .object(let changes)? = events.first?.metadata["changes"] else {
      Issue.record("the changes object is missing")
      return
    }
    for key in [Settings.serverAddress.key, tunnelHost] {
      #expect(changes[key] == .object(["previous": .redacted, "current": .redacted]), "\(key)")
    }
    #expect(
      changes[Settings.socketPort.key] == .object(["previous": .int(1234), "current": .int(1235)]))
    // And nowhere else in the record either: the summary names keys, never values.
    let document = String(decoding: try events[0].json(), as: UTF8.self)
    #expect(!document.contains("example.com"))
  }

  /// What is withheld, pinned. Each says how to reach this server: its published address,
  /// a tunnel's public name, the dynamic DNS URL, and the ntfy topic anyone can subscribe to.
  @Test("The settings that say how to reach this server, and the token, are the confidential ones")
  func confidentialKeysArePinned() {
    let field = { (manifest: ServiceManifest, key: String) in manifest.storageKey(for: key) }
    #expect(
      AuditSettingsBridge.confidentialKeys == [
        Settings.serverAddress.key, Settings.ntfyTopic.key,
        // Rewritten daily by the refresh, and its claims name the licence's subject.
        Settings.licenseToken.key,
        field(BuiltInManifests.zrok, "reserved_name"),
        field(BuiltInManifests.ngrok, "custom_domain"),
        field(BuiltInManifests.cloudflare, "hostname"),
        field(BuiltInManifests.tailscale, "hostname"),
        field(BuiltInManifests.dynamicDNS, "address"),
        field(BuiltInManifests.ntfy, "topic"),
      ])
  }

  /// A new connection method's public name has to be declared confidential, or the audit
  /// log forwards it. Every free-text field of a connection method is either a secret, or
  /// confidential, or named here with the reason it is not about reaching this server.
  @Test("Every free-text field of a connection method is secret, confidential or exempted")
  func connectionMethodFieldsAreClassified() {
    let exempt: [String: String] = [
      "zrok.api_endpoint": "the controller of a self-hosted zrok, not this server",
      "ngrok.host_header": "a header policy, not an address",
      "ngrok.traffic_policy_file": "a path on this Mac",
      "cloudflare.config_file": "a path on this Mac",
      "tailscale.control_url": "a self-hosted control server, not this server",
    ]
    var unclassified: [String] = []
    for manifest in BuiltInManifests.all where manifest.category == .reverseProxy {
      for field in manifest.fields where !field.isSecret && !field.isConfidential {
        switch field.kind {
        case .text, .paragraph, .url:
          let name = "\(manifest.id.rawValue.split(separator: ".").last ?? "").\(field.key)"
          if exempt[name] == nil { unclassified.append(name) }
        default:
          continue
        }
      }
    }
    #expect(unclassified.isEmpty, "declare these isConfidential, or exempt them: \(unclassified)")
  }

  @Test("The settings store reports its writes to the attached observer, with the actor in scope")
  func storeReportsWrites() async throws {
    let (recorder, repository) = try await armedRecorder()
    let store = try await TestSettings.store()
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

  // MARK: - Subscription

  private static func token(
    tier: SubscriptionTier = .pro, ends: Date? = nil, perpetual: Bool = false
  ) -> EntitlementToken {
    EntitlementToken(
      version: 1, subject: "cus_1", tier: tier, features: [], machine: "m",
      issuedAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 1),
      subscriptionEndsAt: ends, identifier: "t", isPerpetual: perpetual)
  }

  @Test("A refusal at the subscription gate is denied, against the client, with the 402's reason")
  func licenseRefusalBridge() async throws {
    let (recorder, repository) = try await armedRecorder()
    let bridge = AuditLicenseRefusalBridge(recorder: recorder)
    bridge.record(
      LicenseRefusalRecord(
        refusal: .noLicense, required: .pro, held: nil, clientAddress: "203.0.113.9",
        route: "/api/v2/chat/:guid/pin"))

    let event = try #require(try await stored(recorder, repository).first)
    #expect(event.kind == .licenseRefused)
    #expect(event.outcome == .denied)
    #expect(event.severity == .warning)
    #expect(event.actor == .client(address: "203.0.113.9"))
    #expect(event.source == .http)
    #expect(event.route == "/api/v2/chat/:guid/pin")
    #expect(event.subject == .client("203.0.113.9"))
    #expect(event.metadata["reason"] == .string("no_license"))
    #expect(event.metadata["required_tier"] == .string("pro"))
    #expect(event.metadata["current_tier"] == .null)
  }

  @Test("Each thing the licence runtime reports maps to its kind, with the dates it knows")
  func licenseBridge() async throws {
    let (recorder, repository) = try await armedRecorder()
    let bridge = AuditLicenseBridge(recorder: recorder)
    let ends = Date(timeIntervalSince1970: 1_800_000_000)

    bridge.record(.statusChanged(previous: nil, current: .active(Self.token(ends: ends))))
    bridge.record(.refreshed(Self.token(perpetual: true)))
    bridge.record(.refreshFailed(reason: "transport(\"offline\")"))
    bridge.record(.revoked)
    bridge.record(.removed(previous: .revoked))

    let events = try await storedByKind(recorder, repository)
    #expect(
      Set(events.keys) == [
        .licenseStatusChanged, .licenseRefreshed, .licenseRefreshFailed, .licenseRevoked,
        .licenseRemoved,
      ])

    let moved = try #require(events[.licenseStatusChanged])
    #expect(moved.actor == .system(component: BuiltInManifests.ID.license.rawValue))
    #expect(moved.severity == .notice)
    #expect(moved.metadata["previous"] == .null)
    #expect(moved.metadata["current"] == .string("active"))
    #expect(moved.metadata["tier"] == .string("pro"))
    #expect(moved.metadata["subscription_ends_at"] == .string(AuditTimestamp.string(from: ends)))

    let refreshed = try #require(events[.licenseRefreshed])
    #expect(refreshed.severity == .info)
    #expect(refreshed.metadata["tier"] == .string("pro"))
    #expect(refreshed.metadata["perpetual"] == .bool(true))
    #expect(refreshed.metadata["subscription_ends_at"] == .null)

    let failed = try #require(events[.licenseRefreshFailed])
    #expect(failed.outcome == .failure)
    #expect(failed.severity == .warning)
    #expect(failed.metadata["reason"] == .string("transport(\"offline\")"))

    #expect(events[.licenseRevoked]?.outcome == .denied)
    #expect(events[.licenseRevoked]?.severity == .warning)
    #expect(events[.licenseRemoved]?.metadata["previous"] == .string("revoked"))
    // Outside any boundary, the exchange and the removal are nobody's; the status move is
    // always the service's.
    #expect(events[.licenseRemoved]?.actor == .unattributed)
  }

  @Test("A move into a status that refuses is a warning; into one that does not, routine")
  func licenseStatusSeverity() {
    #expect(AuditLicenseBridge.severity(of: .none) == .notice)
    #expect(AuditLicenseBridge.severity(of: .active(Self.token())) == .notice)
    #expect(AuditLicenseBridge.severity(of: .expired(at: .distantPast)) == .warning)
    #expect(AuditLicenseBridge.severity(of: .revoked) == .warning)
    #expect(AuditLicenseBridge.severity(of: .machineMismatch) == .warning)
    #expect(AuditLicenseBridge.severity(of: .unverifiable(since: nil)) == .warning)
  }

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
