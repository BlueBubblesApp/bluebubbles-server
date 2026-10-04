//  AuditWiring
//  Where the things that know what happened meet the thing that records it.
//
//  Four modules emit facts in their own vocabulary and none of them may import the audit
//  module: the HTTP layer knows a request finished, the auth layer knows a credential was
//  refused, the access controller knows a client was blocked, the settings store knows a key
//  moved. Each hands a value to a protocol declared beside it, and these bridges are the
//  protocols' production implementations. They translate, redact what the record must not
//  carry, and hand an `AuditEvent` to the recorder, which returns at once.
//
//  Every bridge is a stateless value over the recorder, built in the composition root and
//  nowhere else. The one policy a bridge consults, whether read-only requests are recorded,
//  lives on the recorder (`recordsReadRequests`), where the audit log service can set it
//  without holding the HTTP service's host.
//
//  See `docs/AUDIT_LOG.md`.

import BBAudit
import BBAuth
import BBBuiltIns
import BBCore
import BBHTTPAPI
import BBServiceKit
import BBSettings
import Foundation

// MARK: - Requests

/// Which requests become `api.request` records.
///
/// Off the bridge so it can be asserted: a state-changing request is always recorded, and a
/// read only when the operator asked for reads. `GET` is the one read method the route table
/// has; the table's `HTTPMethod` has four cases and the other three all change state.
enum AuditRequestPolicy {
  static func shouldRecord(method: HTTPMethod, recordsReads: Bool) -> Bool {
    switch method {
    case .get: recordsReads
    case .post, .put, .delete: true
    }
  }

  /// What a status says about how the request went. A refusal is `denied`, so a SIEM rule
  /// for "denied actions" finds a 401 and a 403 without knowing HTTP.
  static func outcome(forStatus status: Int) -> AuditOutcome {
    switch status {
    case ..<400: .success
    case 401, 403: .denied
    default: .failure
    }
  }
}

/// Turns a finished request into its transport record.
struct AuditRequestBridge: Sendable {

  let recorder: AuditRecorder

  func requestCompleted(_ record: RequestAuditRecord) {
    guard
      AuditRequestPolicy.shouldRecord(
        method: record.method, recordsReads: recorder.recordsReadRequests)
    else { return }
    let outcome = AuditRequestPolicy.outcome(forStatus: record.status)
    recorder.record(
      AuditEvent(
        kind: .apiRequest,
        outcome: outcome,
        actor: .client(address: record.clientAddress),
        source: .http,
        requestID: record.requestID,
        route: record.routeTemplate,
        subject: .route(record.routeTemplate),
        summary: "\(record.method.rawValue) \(record.routeTemplate) answered \(record.status).",
        metadata: [
          "method": .string(record.method.rawValue),
          "handler": .string(record.handlerID.rawValue),
          "status": .int(record.status),
          "duration_ms": .int(Int(record.duration.milliseconds)),
          "authenticated": .bool(record.isAuthenticated),
        ]
      ))
  }
}

// MARK: - Authentication

/// Turns a refusal from either transport into an authentication record.
struct AuditAuthenticationBridge: AuthenticationAuditing {

  let recorder: AuditRecorder

  func record(_ event: AuthenticationAuditEvent) {
    let who = event.clientAddress ?? "an unidentified client"
    let where_ = event.route ?? "an unknown route"
    let transport = AuditValue.string(event.transport.rawValue)
    let source: AuditSource = event.transport == .socket ? .socket : .http

    let kind: AuditEventKind
    let summary: String
    var metadata: [String: AuditValue] = ["transport": transport]
    switch event.kind {
    case .credentialRejected(let reason):
      kind = .credentialRejected
      summary = "A credential from \(who) was rejected on \(where_)."
      metadata["reason"] = .string(reason)
    case .credentialMissing:
      kind = .credentialMissing
      summary = "\(who) called \(where_) without a credential."
    case .blocked:
      kind = .requestBlocked
      summary = "A request from \(who) to \(where_) was refused: the client is blocked."
    case .scopeRefused(let scope):
      kind = .scopeRefused
      summary = "A credential from \(who) lacks the \(scope) scope that \(where_) requires."
      metadata = ["scope": .string(scope)]
    }

    recorder.record(
      AuditEvent(
        kind: kind,
        outcome: .denied,
        actor: .client(address: event.clientAddress),
        source: source,
        route: event.route,
        subject: event.clientAddress.map(AuditSubject.client),
        summary: summary,
        metadata: metadata
      ))
  }
}

// MARK: - Access control

/// Turns a change to the blocklist or the allowlist into a record.
///
/// The actor is whoever the task-local names: the server for an automatic block, which
/// happens inside a request and is still the SERVER's decision, so it is named explicitly;
/// the operator or a client for the administered changes, which come through the window or
/// the security routes.
struct AuditAccessControlBridge: AccessControlAuditing {

  let recorder: AuditRecorder

  func record(_ event: AccessControlAuditEvent) {
    switch event {
    case .clientBlocked(let address, let reason, let failureCount, let offenceCount, let expiresAt):
      recorder.record(
        AuditEvent(
          kind: .clientBlocked,
          outcome: .success,
          actor: .system(component: "access-control"),
          subject: .client(address),
          summary: "\(address) was blocked after \(failureCount) failed logins.",
          metadata: [
            "failure_count": .int(failureCount),
            "offence_count": .int(offenceCount),
            "expires_at": .string(AuditTimestamp.string(from: expiresAt)),
            "reason": .string(reason),
          ]
        ))
    case .clientBlockedPermanently(let address, let reason):
      recorder.record(
        AuditEvent(
          kind: .clientBlockedPermanently,
          subject: .client(address),
          summary: "\(address) was blocked permanently.",
          metadata: ["reason": .string(reason)]
        ))
    case .clientUnblocked(let address):
      recorder.record(
        AuditEvent(
          kind: .clientUnblocked, subject: .client(address),
          summary: "\(address) was unblocked."))
    case .blocksCleared(let count):
      recorder.record(
        AuditEvent(
          kind: .blocksCleared,
          summary: "Every block was cleared (\(count) lifted).",
          metadata: ["count": .int(count)]
        ))
    case .clientAllowlisted(let cidr, let note):
      recorder.record(
        AuditEvent(
          kind: .clientAllowlisted,
          subject: .allowlistEntry(cidr),
          summary: "\(cidr) was added to the allowlist.",
          metadata: note.map { ["note": .string($0)] } ?? [:]
        ))
    case .allowlistEntryRemoved(let cidr):
      recorder.record(
        AuditEvent(
          kind: .allowlistEntryRemoved, subject: .allowlistEntry(cidr),
          summary: "\(cidr) was removed from the allowlist."))
    case .loginsThrottled(let failureCount):
      recorder.record(
        AuditEvent(
          kind: .loginsThrottled,
          outcome: .denied,
          actor: .system(component: "access-control"),
          summary: "Failed logins from an unidentifiable source are being throttled "
            + "(\(failureCount) in the window).",
          metadata: ["failure_count": .int(failureCount)]
        ))
    }
  }
}

// MARK: - Settings

/// Turns a settings write into `settings.changed`, and a change to the service switch into
/// `service.enabled` / `service.disabled` as well.
///
/// The second record is derived here rather than left to a SIEM to work out: "the audit log
/// was switched off" is the one rule every deployment of this feature writes first, and
/// asking it to parse a comma-separated list out of a settings diff would be asking it to
/// know how `disabled_services` is spelled.
struct AuditSettingsBridge: SettingsWriteObserving {

  let recorder: AuditRecorder

  func settingsDidChange(_ record: SettingsWriteRecord) {
    if !record.changes.isEmpty {
      var changes: [String: AuditValue] = [:]
      for change in record.changes {
        changes[change.key] = .object([
          "previous": Self.value(change.previousJSON, isSecret: change.isSecret),
          "current": Self.value(change.currentJSON, isSecret: change.isSecret),
        ])
      }
      let keys = record.changes.map(\.key).sorted()
      recorder.record(
        AuditEvent(
          kind: .settingsChanged,
          subject: keys.count == 1 ? keys.first.map(AuditSubject.setting) : nil,
          summary: keys.count == 1
            ? "The setting \(keys[0]) was changed."
            : "\(keys.count) settings were changed: \(keys.joined(separator: ", ")).",
          metadata: [
            "changes": .object(changes),
            "keys": .array(keys.map(AuditValue.string)),
          ]
        ))
      for change in record.changes where change.key == Settings.disabledServicesKey {
        recordServiceSwitches(previous: change.previousJSON, current: change.currentJSON)
      }
    }
    if !record.removedKeys.isEmpty {
      let keys = record.removedKeys.sorted()
      recorder.record(
        AuditEvent(
          kind: .settingsRemoved,
          subject: keys.count == 1 ? keys.first.map(AuditSubject.setting) : nil,
          summary: keys.count == 1
            ? "The setting \(keys[0]) was removed."
            : "\(keys.count) settings were removed: \(keys.joined(separator: ", ")).",
          metadata: ["keys": .array(keys.map(AuditValue.string))]
        ))
    }
  }

  /// A stored value as the record carries it: redacted for a secret, `null` for unset, and
  /// otherwise whatever JSON the row holds, which is the value's real type.
  static func value(_ json: Data?, isSecret: Bool) -> AuditValue {
    if isSecret { return .redacted }
    guard let json, !json.isEmpty else { return .null }
    return (try? AuditJSON.decode(AuditValue.self, from: json))
      ?? .string(String(decoding: json, as: UTF8.self))
  }

  /// The services whose switch moved, as the stored list before and after.
  static func switched(previous: Data?, current: Data?) -> (on: [String], off: [String]) {
    func identifiers(_ json: Data?) -> Set<String> {
      guard let json, let raw = try? AuditJSON.decode(String.self, from: json) else { return [] }
      return ServiceEnablement.disabledIdentifiers(in: raw)
    }
    let before = identifiers(previous)
    let after = identifiers(current)
    return (on: before.subtracting(after).sorted(), off: after.subtracting(before).sorted())
  }

  private func recordServiceSwitches(previous: Data?, current: Data?) {
    let moved = Self.switched(previous: previous, current: current)
    for id in moved.off { recordSwitch(id, kind: .serviceDisabled, verb: "switched off") }
    for id in moved.on { recordSwitch(id, kind: .serviceEnabled, verb: "switched on") }
  }

  private func recordSwitch(_ id: String, kind: AuditEventKind, verb: String) {
    let name = BuiltInManifests.all.first { $0.id.rawValue == id }?.name ?? id
    recorder.record(
      AuditEvent(
        kind: kind,
        subject: .service(id),
        summary: "\(name) was \(verb).",
        metadata: ["service_name": .string(name)]
      ))
  }
}
