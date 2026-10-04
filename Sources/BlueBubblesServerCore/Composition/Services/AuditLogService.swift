//  AuditLogService
//  The switch on the audit log, and the owner of everything that runs while it is on.
//
//  The recorder that every emitter holds exists whether or not this service does; what this
//  service adds is a reason for it to keep anything. On start it arms the recorder with the
//  table and, when forwarding is configured, a syslog forwarder; on stop it disarms it, and
//  the recorder goes back to dropping. So "switch the audit log off" is this service stopping
//  and nothing else: no other service restarts and no emitter is told.
//
//  Three things run for as long as the service does:
//
//    - the retention sweep, once at start and once a day, so the table has a ceiling;
//    - the health follower, which turns the registry's snapshots into `service.started`,
//      `service.stopped` and `service.failed` records for every OTHER service: a transition
//      the registry performs is not visible to the service it performs it on, so the one
//      service that watches the whole table has to write them;
//    - the forwarder, whose state changes become one alert and one record each way.
//
//  Every field is read once, at start. A change to any of them restarts the service, which
//  re-reads them; there is no live reconfiguration, because the forwarder's connection and
//  the recorder's exporters are built from those fields and rebuilding them IS a restart.
//
//  See `docs/AUDIT_LOG.md`.

import BBAudit
import BBBuiltIns
import BBCore
import BBDiagnostics
import BBInterfaces
import BBServiceKit
import BBSettings
import Foundation
import Logging

actor AuditLogService: Service, ConfigurableService {

  static let manifest = BuiltInManifests.auditLog

  /// What this service touches, rather than the container that holds it.
  typealias Host = any AuditRecorderProviding & AppDatabaseProviding & SettingsProviding
    & AlertProviding & ServiceHealthObserving

  /// The dedupe key of the one alert this service raises. A prefix dismissal clears it.
  static let forwardingAlertKey = "audit.syslog.failing"

  private let host: Host
  private let recorder: AuditRecorder
  private let repository: AuditRepository
  private let scoped: ScopedSettings
  private let alerts: AlertCenter
  private let logger = Logger(label: "bluebubbles.audit")

  private var retention = AuditRetentionPolicy.default
  private var forwarder: SyslogForwarder?
  private var forwardingTransport: SyslogTransportKind?
  private var forwardingFailure: String?
  private var sweep: Task<Void, Never>?
  private var follower: Task<Void, Never>?
  private var lastKnownHealth: [ServiceIdentifier: ServiceHealth] = [:]

  init(host: Host) {
    self.host = host
    self.recorder = host.auditLog
    self.repository = AuditRepository(database: host.appDatabase)
    self.scoped = ScopedSettings(
      store: host.settings, manifest: Self.manifest, secretKeys: Settings.secretKeys)
    self.alerts = host.alerts
  }

  /// The manifest's own fields, secrets included.
  ///
  /// `manifestWatchedSettings` is built from declared entitlements and this service declares
  /// no `readSettings`: its configuration is its own namespace, which the scope grants
  /// without one. The TLS fields are in the set because a replaced certificate has to rebuild
  /// the connection like any other field.
  static var watchedSettings: Set<String> {
    manifestWatchedSettings.union(manifest.fields.map { manifest.storageKey(for: $0.key) })
  }

  // MARK: - Lifecycle

  func start() async throws {
    retention = AuditRetentionPolicy.parse(await scoped.own(AuditLogField.retentionDays))
    let recordsReads = await scoped.ownFlag(AuditLogField.recordReads)

    var exporters: [any AuditExporter] = []
    forwardingTransport = nil
    forwardingFailure = nil
    if await scoped.ownFlag(AuditLogField.syslogEnabled) {
      if let destination = await syslogDestination() {
        let forwarder = SyslogForwarder(
          destination: destination,
          hostname: Self.hostname(),
          softwareVersion: Self.softwareVersion,
          onStateChange: { [weak self] state in await self?.forwardingStateChanged(state) }
        )
        self.forwarder = forwarder
        forwardingTransport = destination.transport
        exporters.append(forwarder)
      } else {
        // Switched on with nowhere to send to. Not a failure to start: the local copy is
        // the record and it still works. Said once, where the person can act on it.
        forwardingFailure = "No syslog receiver is set."
        await alerts.raise(
          UserAlert(
            severity: .warning,
            title: "Audit records are not being forwarded",
            body: "Syslog forwarding is on but no receiver is set. Enter the receiver's "
              + "address in the Audit Log integration, or switch forwarding off.",
            source: "Audit Log",
            actions: [.openSettings(.features)],
            dedupeKey: Self.forwardingAlertKey,
            isDurable: false
          ))
      }
    }

    await recorder.arm(store: repository, exporters: exporters)
    recorder.setRecordsReadRequests(recordsReads)
    logger.info(
      "Audit log recording",
      metadata: [
        "retentionDays": .stringConvertible(retention.days),
        "forwarding": .string(forwardingTransport?.rawValue ?? "off"),
        "recordsReads": .stringConvertible(recordsReads),
      ])

    // Waited for, so the start is the first row of the run whatever else is being recorded
    // while the service comes up.
    await recorder.recordNow(
      AuditEvent(
        kind: .recordingStarted,
        subject: .service(Self.manifest.id.rawValue),
        summary: "Audit recording started; records \(retention.summary).",
        metadata: [
          "retention_days": .int(retention.days),
          "forwarding": .string(forwardingTransport?.rawValue ?? "off"),
          "records_reads": .bool(recordsReads),
        ]
      ))

    // The sweep runs BEFORE its first sleep, so a server that was off past a retention
    // boundary trims on the way up rather than tomorrow.
    sweep?.cancel()
    sweep = Task { [weak self] in
      while !Task.isCancelled {
        await self?.applyRetention()
        // Cancellation is the only error `Task.sleep` throws, and the loop checks it next.
        try? await Task.sleep(for: AuditRetentionPolicy.sweepInterval)
      }
    }

    lastKnownHealth = await host.serviceHealthSnapshot()
    follower?.cancel()
    if let changes = await host.serviceHealthChanges() {
      follower = Task { [weak self] in
        for await snapshot in changes {
          guard !Task.isCancelled else { return }
          await self?.healthDidChange(to: snapshot)
        }
      }
    }
  }

  func stop() async {
    follower?.cancel()
    follower = nil
    sweep?.cancel()
    sweep = nil
    // Queued BEFORE the recorder disarms, and waited for, so the stop is the last row the run
    // writes and reaches the receiver with everything before it.
    await recorder.recordNow(
      AuditEvent(
        kind: .recordingStopped,
        subject: .service(Self.manifest.id.rawValue),
        summary: "Audit recording stopped."
      ))
    await recorder.disarm()
    forwarder = nil
    forwardingTransport = nil
    forwardingFailure = nil
    await alerts.dismiss(dedupeKeyPrefix: Self.forwardingAlertKey)
  }

  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      if let forwardingFailure {
        return .degraded(reason: forwardingFailure)
      }
      return sweep != nil ? .running : .stopped
    }
  }

  /// The sweep is the one thing that can quietly stop; without it the table grows for ever.
  var isAlive: Bool { get async { sweep != nil } }

  // MARK: - Configuration

  /// Where records are forwarded, from the manifest's fields, or nil when no receiver is
  /// named. The three PEM fields come from the Keychain by way of the store, which routes a
  /// secret key there; an unreadable Keychain reads as empty, and the forwarder then reports
  /// the handshake failure that follows, which is the right place for it to surface.
  private func syslogDestination() async -> SyslogDestination? {
    let host = await scoped.own(AuditLogField.syslogHost).trimmingCharacters(in: .whitespaces)
    guard !host.isEmpty else { return nil }
    let port = Int(await scoped.own(AuditLogField.syslogPort).trimmingCharacters(in: .whitespaces))
    return SyslogDestination(
      host: host,
      port: port,
      transport: SyslogTransportKind.parse(await scoped.own(AuditLogField.syslogTransport)),
      facility: SyslogFacility.parse(await scoped.own(AuditLogField.syslogFacility)),
      tls: SyslogTLSMaterial(
        trustedCertificatePEM: await scoped.own(AuditLogField.syslogTrustedCertificate),
        clientCertificatePEM: await scoped.own(AuditLogField.syslogClientCertificate),
        clientPrivateKeyPEM: await scoped.own(AuditLogField.syslogClientPrivateKey)
      )
    )
  }

  /// This Mac's name as the kernel has it, for the syslog `HOSTNAME` field. Not
  /// `ProcessInfo.hostName`, which can wait on a DNS lookup to answer.
  static func hostname() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else { return "localhost" }
    let name = String(cString: buffer)
    return name.isEmpty ? "localhost" : name
  }

  /// This build's version, for the syslog `origin` element. Nil from a bare `swift run`,
  /// which has no bundle to read.
  static var softwareVersion: String? {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
  }

  // MARK: - Retention

  func applyRetention(now: Date = Date()) async {
    guard let cutoff = retention.cutoff(now: now) else { return }
    do {
      let deleted = try await repository.deleteOlderThan(cutoff)
      guard deleted > 0 else { return }
      logger.info(
        "Audit retention applied",
        metadata: [
          "deleted": .stringConvertible(deleted),
          "retentionDays": .stringConvertible(retention.days),
        ])
      recorder.record(
        AuditEvent(
          kind: .retentionApplied,
          actor: .system(component: Self.manifest.id.rawValue),
          summary: "\(deleted) audit records older than \(retention.days) days were removed.",
          metadata: [
            "deleted_count": .int(deleted),
            "retention_days": .int(retention.days),
            "cutoff": .string(AuditTimestamp.string(from: cutoff)),
          ]
        ))
    } catch {
      logger.error(
        "Could not apply audit retention",
        metadata: ["error": .string(String(describing: error))])
    }
  }

  // MARK: - Other services

  /// Which transitions become records. Off the actor so the diff can be asserted without a
  /// registry: `starting` is a transition in progress and writes nothing; `degraded` is
  /// running with a complaint, so it is not a stop; a repeated `failed` with the same reason
  /// is one failure, not two.
  enum HealthTransition: Equatable {
    case started
    case stopped
    case failed(reason: String)

    static func between(_ previous: ServiceHealth?, _ current: ServiceHealth)
      -> HealthTransition?
    {
      switch current {
      case .starting:
        return nil
      case .running, .degraded:
        return previous.map(isUp) == true ? nil : .started
      case .stopped, .inactive:
        return previous.map(isUp) == true ? .stopped : nil
      case .failed(let reason):
        if case .failed(let before)? = previous, before == reason { return nil }
        return .failed(reason: reason)
      }
    }

    private static func isUp(_ health: ServiceHealth) -> Bool {
      switch health {
      case .running, .degraded: true
      case .stopped, .starting, .failed, .inactive: false
      }
    }
  }

  private func healthDidChange(to snapshot: [ServiceIdentifier: ServiceHealth]) {
    let previous = lastKnownHealth
    lastKnownHealth = snapshot
    for (id, health) in snapshot where id != Self.id {
      guard let transition = HealthTransition.between(previous[id], health) else { continue }
      let name = BuiltInManifests.all.first { $0.id == id }?.name ?? id.rawValue
      let kind: AuditEventKind
      let summary: String
      var metadata: [String: AuditValue] = ["service_name": .string(name)]
      var outcome = AuditOutcome.success
      switch transition {
      case .started:
        kind = .serviceStarted
        summary = "\(name) started."
      case .stopped:
        kind = .serviceStopped
        summary = "\(name) stopped."
      case .failed(let reason):
        kind = .serviceFailed
        summary = "\(name) failed: \(reason)"
        metadata["reason"] = .string(reason)
        outcome = .failure
      }
      recorder.record(
        AuditEvent(
          kind: kind,
          outcome: outcome,
          actor: .system(component: "service-registry"),
          subject: .service(id.rawValue),
          summary: summary,
          metadata: metadata
        ))
    }
  }

  // MARK: - Forwarding

  private func forwardingStateChanged(_ state: SyslogForwardingState) async {
    let transport = forwardingTransport?.rawValue ?? "off"
    switch state {
    case .idle:
      return
    case .failing(let reason):
      let wasFailing = forwardingFailure != nil
      forwardingFailure = reason
      await alerts.raise(
        UserAlert(
          severity: .warning,
          title: "Audit records are not reaching the syslog receiver",
          body: "\(reason) Records are kept locally and will be forwarded once the receiver "
            + "is reachable again.",
          source: "Audit Log",
          actions: [.openSettings(.features)],
          dedupeKey: Self.forwardingAlertKey,
          isDurable: false
        ))
      // One record per outage, not one per retry: the forwarder reports every change of
      // reason, and a receiver that is down produces a new reason each time the error text
      // carries a different port or timing.
      guard !wasFailing else { return }
      recorder.record(
        AuditEvent(
          kind: .forwardingFailed,
          outcome: .failure,
          actor: .system(component: Self.manifest.id.rawValue),
          summary: "Audit records stopped reaching the syslog receiver.",
          metadata: ["transport": .string(transport), "reason": .string(reason)]
        ))
    case .connected:
      guard forwardingFailure != nil else { return }
      forwardingFailure = nil
      await alerts.dismiss(dedupeKeyPrefix: Self.forwardingAlertKey)
      recorder.record(
        AuditEvent(
          kind: .forwardingRestored,
          actor: .system(component: Self.manifest.id.rawValue),
          summary: "Audit records are reaching the syslog receiver again.",
          metadata: ["transport": .string(transport)]
        ))
    }
  }
}
