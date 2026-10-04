//  AuditEventKind
//  Every kind of event the audit log records, and what each one carries.
//
//  The catalogue is a closed enum rather than free text for the reason every other
//  vocabulary in this server is: a kind is what a SIEM rule matches on, so two spellings of
//  one event are two rules that each miss half the occurrences. Adding a kind means adding a
//  case here, which makes the switches below exhaustive, and documenting it in
//  `docs/AUDIT_LOG.md`, which `AuditCatalogDocumentationTests` enforces.
//
//  Each kind declares the METADATA FIELDS it carries. That declaration is the schema a person
//  writing a query against the JSON column (in Postgres, in Splunk, in a CSV) reads, and it is
//  checked against the document rather than trusted: a field an emitter writes and nobody
//  documented is a column nobody can find.
//
//  The raw values are a contract once a receiver has stored them: renaming a case is free,
//  changing its string is a break for every rule written against it.
//
//  See `docs/AUDIT_LOG.md`.

import Foundation

/// The group a kind belongs to, and the syslog `MSGID`.
public enum AuditCategory: String, Sendable, Hashable, Codable, CaseIterable {
  /// A credential presented and judged.
  case authentication = "auth"
  /// The blocklist and the allowlist.
  case accessControl = "access_control"
  case settings
  /// A service's lifecycle and its switch.
  case service
  /// A state-changing API request.
  case api
  case webhook
  case scheduledMessage = "scheduled_message"
  /// The audit log's own lifecycle: recording, retention, export, forwarding.
  case audit

  /// What a person reads in a filter.
  public var title: String {
    switch self {
    case .authentication: "Authentication"
    case .accessControl: "Access control"
    case .settings: "Settings"
    case .service: "Services"
    case .api: "API requests"
    case .webhook: "Webhooks"
    case .scheduledMessage: "Scheduled messages"
    case .audit: "Audit log"
    }
  }
}

/// The type of one metadata field, in the vocabulary a document reader needs.
public enum AuditFieldType: String, Sendable, Hashable {
  case string
  case integer
  case boolean
  case number
  /// A JSON array of strings.
  case stringArray = "array of strings"
  /// A JSON object whose keys are documented by the field's description.
  case object
}

/// One documented key of a kind's `metadata`.
public struct AuditMetadataField: Sendable, Hashable {
  public let name: String
  public let type: AuditFieldType
  public let description: String

  public init(_ name: String, _ type: AuditFieldType, _ description: String) {
    self.name = name
    self.type = type
    self.description = description
  }
}

public enum AuditEventKind: String, Sendable, Hashable, Codable, CaseIterable {

  // MARK: Authentication

  /// A credential was presented and did not match.
  case credentialRejected = "auth.credential_rejected"
  /// A route that needs a credential was called without one.
  case credentialMissing = "auth.credential_missing"
  /// A request from a blocked client was refused before its credential was read.
  case requestBlocked = "auth.request_blocked"
  /// A valid credential lacked the scope the route requires.
  case scopeRefused = "auth.scope_refused"

  // MARK: Access control

  /// The failure threshold blocked a client for a while.
  case clientBlocked = "access_control.client_blocked"
  /// An operator blocked a client with no expiry.
  case clientBlockedPermanently = "access_control.client_blocked_permanently"
  case clientUnblocked = "access_control.client_unblocked"
  case blocksCleared = "access_control.blocks_cleared"
  case clientAllowlisted = "access_control.client_allowlisted"
  case allowlistEntryRemoved = "access_control.allowlist_entry_removed"
  /// Failures from an unidentifiable source crossed the global threshold.
  case loginsThrottled = "access_control.logins_throttled"

  // MARK: Settings

  case settingsChanged = "settings.changed"
  case settingsRemoved = "settings.removed"

  // MARK: Services

  case serviceStarted = "service.started"
  case serviceStopped = "service.stopped"
  case serviceFailed = "service.failed"
  /// The Integrations switch, or the setting behind it, turned a service on.
  case serviceEnabled = "service.enabled"
  case serviceDisabled = "service.disabled"

  // MARK: API

  /// A state-changing request (`POST`, `PUT`, `DELETE`) completed, however it ended. A
  /// read is recorded only when the operator asks for reads.
  case apiRequest = "api.request"

  // MARK: Webhooks

  case webhookCreated = "webhook.created"
  case webhookUpdated = "webhook.updated"
  case webhookDeleted = "webhook.deleted"

  // MARK: Scheduled messages

  case scheduledMessageCreated = "scheduled_message.created"
  case scheduledMessageUpdated = "scheduled_message.updated"
  case scheduledMessageDeleted = "scheduled_message.deleted"
  case scheduledMessageSent = "scheduled_message.sent"
  case scheduledMessageFailed = "scheduled_message.failed"

  // MARK: The audit log itself

  case recordingStarted = "audit.recording_started"
  case recordingStopped = "audit.recording_stopped"
  case retentionApplied = "audit.retention_applied"
  case exported = "audit.exported"
  /// The syslog receiver stopped accepting records.
  case forwardingFailed = "audit.forwarding_failed"
  case forwardingRestored = "audit.forwarding_restored"
  /// Records were lost: the forwarding queue overflowed, or the recorder's buffer did.
  case eventsDropped = "audit.events_dropped"

  public var category: AuditCategory {
    switch self {
    case .credentialRejected, .credentialMissing, .requestBlocked, .scopeRefused:
      .authentication
    case .clientBlocked, .clientBlockedPermanently, .clientUnblocked, .blocksCleared,
      .clientAllowlisted, .allowlistEntryRemoved, .loginsThrottled:
      .accessControl
    case .settingsChanged, .settingsRemoved:
      .settings
    case .serviceStarted, .serviceStopped, .serviceFailed, .serviceEnabled, .serviceDisabled:
      .service
    case .apiRequest:
      .api
    case .webhookCreated, .webhookUpdated, .webhookDeleted:
      .webhook
    case .scheduledMessageCreated, .scheduledMessageUpdated, .scheduledMessageDeleted,
      .scheduledMessageSent, .scheduledMessageFailed:
      .scheduledMessage
    case .recordingStarted, .recordingStopped, .retentionApplied, .exported, .forwardingFailed,
      .forwardingRestored, .eventsDropped:
      .audit
    }
  }

  /// The severity a record of this kind gets unless the emitter says otherwise.
  ///
  /// A refusal or a failure is at least a warning whatever the kind, which is why the
  /// outcome is an input: `api.request` is routine when it succeeds and worth a look when
  /// it did not.
  public func defaultSeverity(for outcome: AuditOutcome) -> AuditSeverity {
    let base: AuditSeverity =
      switch self {
      case .credentialRejected, .credentialMissing, .requestBlocked, .scopeRefused,
        .clientBlocked, .loginsThrottled, .serviceFailed, .scheduledMessageFailed,
        .forwardingFailed:
        .warning
      case .eventsDropped:
        .critical
      case .clientBlockedPermanently, .clientUnblocked, .blocksCleared, .clientAllowlisted,
        .allowlistEntryRemoved, .settingsChanged, .settingsRemoved, .serviceStarted,
        .serviceStopped, .serviceEnabled, .serviceDisabled, .webhookCreated, .webhookUpdated,
        .webhookDeleted, .scheduledMessageCreated, .scheduledMessageUpdated,
        .scheduledMessageDeleted, .recordingStarted, .recordingStopped, .retentionApplied,
        .exported, .forwardingRestored:
        .notice
      case .apiRequest, .scheduledMessageSent:
        .info
      }
    switch outcome {
    case .success: return base
    case .failure, .denied: return max(base, .warning)
    }
  }

  /// A short title for a list row or a filter.
  public var title: String {
    switch self {
    case .credentialRejected: "Credential rejected"
    case .credentialMissing: "Credential missing"
    case .requestBlocked: "Request blocked"
    case .scopeRefused: "Scope refused"
    case .clientBlocked: "Client blocked"
    case .clientBlockedPermanently: "Client blocked permanently"
    case .clientUnblocked: "Client unblocked"
    case .blocksCleared: "Blocks cleared"
    case .clientAllowlisted: "Client allowlisted"
    case .allowlistEntryRemoved: "Allowlist entry removed"
    case .loginsThrottled: "Logins throttled"
    case .settingsChanged: "Settings changed"
    case .settingsRemoved: "Settings removed"
    case .serviceStarted: "Service started"
    case .serviceStopped: "Service stopped"
    case .serviceFailed: "Service failed"
    case .serviceEnabled: "Service enabled"
    case .serviceDisabled: "Service disabled"
    case .apiRequest: "API request"
    case .webhookCreated: "Webhook created"
    case .webhookUpdated: "Webhook updated"
    case .webhookDeleted: "Webhook deleted"
    case .scheduledMessageCreated: "Scheduled message created"
    case .scheduledMessageUpdated: "Scheduled message updated"
    case .scheduledMessageDeleted: "Scheduled message deleted"
    case .scheduledMessageSent: "Scheduled message sent"
    case .scheduledMessageFailed: "Scheduled message failed"
    case .recordingStarted: "Recording started"
    case .recordingStopped: "Recording stopped"
    case .retentionApplied: "Retention applied"
    case .exported: "Exported"
    case .forwardingFailed: "Forwarding failed"
    case .forwardingRestored: "Forwarding restored"
    case .eventsDropped: "Events dropped"
    }
  }

  /// The `metadata` keys a record of this kind carries. The documentation test checks that
  /// every one is listed in `docs/AUDIT_LOG.md`, and `AuditEventKindTests` that every
  /// emitter in this repository writes only these.
  public var metadataFields: [AuditMetadataField] {
    switch self {
    case .credentialRejected:
      return [
        .init("reason", .string, "Why the credential was refused, as the server's own code."),
        .init("transport", .string, "`http` or `socket`."),
      ]
    case .credentialMissing:
      return [.init("transport", .string, "`http` or `socket`.")]
    case .requestBlocked:
      return [.init("transport", .string, "`http` or `socket`.")]
    case .scopeRefused:
      return [.init("scope", .string, "The scope the route requires.")]
    case .clientBlocked:
      return [
        .init("failure_count", .integer, "Failures counted against the client in the window."),
        .init("offence_count", .integer, "How many times this client has been blocked."),
        .init("expires_at", .string, "When the block lapses, RFC 3339 UTC."),
        .init("reason", .string, "The last failure's reason."),
      ]
    case .clientBlockedPermanently:
      return [.init("reason", .string, "The operator's reason.")]
    case .clientUnblocked:
      return []
    case .blocksCleared:
      return [.init("count", .integer, "How many blocks were lifted.")]
    case .clientAllowlisted:
      return [.init("note", .string, "The operator's note, when one was given.")]
    case .allowlistEntryRemoved:
      return []
    case .loginsThrottled:
      return [.init("failure_count", .integer, "Unattributable failures in the window.")]
    case .settingsChanged:
      return [
        .init(
          "changes", .object,
          "One entry per key: `{\"<key>\": {\"previous\": …, \"current\": …}}`. A secret's "
            + "values are `••••`; an unset value is `null`."),
        .init("keys", .stringArray, "The keys that changed, for filtering."),
      ]
    case .settingsRemoved:
      return [.init("keys", .stringArray, "The keys that were removed.")]
    case .serviceStarted, .serviceStopped:
      return [.init("service_name", .string, "The service's display name.")]
    case .serviceFailed:
      return [
        .init("service_name", .string, "The service's display name."),
        .init("reason", .string, "The failure, as the registry reported it."),
      ]
    case .serviceEnabled, .serviceDisabled:
      return [.init("service_name", .string, "The service's display name.")]
    case .apiRequest:
      return [
        .init("method", .string, "The HTTP method."),
        .init("handler", .string, "The handler identifier, such as `message.sendText`."),
        .init("status", .integer, "The HTTP status the client received."),
        .init("duration_ms", .integer, "How long the request took, in milliseconds."),
        .init("authenticated", .boolean, "Whether a credential was accepted."),
      ]
    case .webhookCreated, .webhookUpdated:
      return [
        .init("url", .string, "The endpoint, with any credential in its query removed."),
        .init("events", .stringArray, "The events it subscribes to; `*` means all."),
        .init("follow_redirects", .boolean, "Whether delivery follows a redirect."),
      ]
    case .webhookDeleted:
      return []
    case .scheduledMessageCreated, .scheduledMessageUpdated:
      return [
        .init("type", .string, "The scheduled action, `send-message` for every client so far."),
        .init("scheduled_for", .string, "When it is due, RFC 3339 UTC."),
        .init("recurring", .boolean, "Whether it repeats."),
      ]
    case .scheduledMessageDeleted:
      return [
        .init(
          "count", .integer,
          "How many rows went, present only when the finished history was cleared at once.")
      ]
    case .scheduledMessageSent:
      return [
        .init("type", .string, "The scheduled action."),
        .init(
          "next_occurrence", .string,
          "When the series fires next, RFC 3339 UTC, or `null` for a one-shot."),
      ]
    case .scheduledMessageFailed:
      return [
        .init("type", .string, "The scheduled action."),
        .init("reason", .string, "Why the send failed."),
      ]
    case .recordingStarted:
      return [
        .init("retention_days", .integer, "The retention in force; 0 means forever."),
        .init("forwarding", .string, "`off`, or the syslog transport in use."),
        .init("records_reads", .boolean, "Whether read-only API requests are recorded."),
      ]
    case .recordingStopped:
      return []
    case .retentionApplied:
      return [
        .init("deleted_count", .integer, "How many records the sweep removed."),
        .init("retention_days", .integer, "The retention in force."),
        .init("cutoff", .string, "Records older than this were removed, RFC 3339 UTC."),
      ]
    case .exported:
      return [
        .init("format", .string, "`csv`."),
        .init("record_count", .integer, "How many records the export holds."),
        .init("filtered", .boolean, "Whether a filter narrowed the export."),
      ]
    case .forwardingFailed:
      return [
        .init("transport", .string, "`tls`, `tcp` or `udp`."),
        .init("reason", .string, "What the connection or write failed with."),
      ]
    case .forwardingRestored:
      return [.init("transport", .string, "`tls`, `tcp` or `udp`.")]
    case .eventsDropped:
      return [
        .init("dropped_count", .integer, "How many records were lost."),
        .init("where", .string, "`forwarding_queue` or `recorder_buffer`."),
      ]
    }
  }
}
