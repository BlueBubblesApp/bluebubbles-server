//  AuditEvent
//  One thing that happened, in the shape every consumer of the audit log reads.
//
//  The record is the contract. It is stored as a row, exported as a CSV line, forwarded as a
//  syslog message and rendered on a page, and all four read THIS value, so a field added here
//  reaches every one of them and a field renamed here renames it everywhere at once. The
//  envelope (who, when, what kind, what outcome, which subject) is the same for every kind of
//  event; what differs between kinds lives in `metadata`, whose keys each kind declares in
//  `AuditEventKind.metadataFields` and `docs/AUDIT_LOG.md` documents for the people writing
//  queries against it.
//
//  Two rules about what goes IN a record, because an audit log is the artefact most likely
//  to leave this Mac:
//
//    - No message content, no subjects, no display names, no credentials. A record says that
//      a message was sent to a route, never what it said. The one address that appears is a
//      CLIENT address (an IP), which is what an operator blocks and unblocks and is the whole
//      point of an authentication record.
//    - No secret values. A settings change to a secret key records that the key changed and
//      nothing else; `AuditValue.redacted` is what the metadata carries in its place.
//
//  See `docs/AUDIT_LOG.md`.

import BBCore
import Foundation

/// A metadata value: JSON, as a closed type so a record cannot carry something that does not
/// serialise.
///
/// Its own type rather than `JSONValue` from the serialization module, so the audit module
/// sits below the message layer: an audit record about a settings change should not have to
/// link the iMessage schema to say what the new value was.
public indirect enum AuditValue: Sendable, Hashable, Codable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null
  case array([AuditValue])
  case object([String: AuditValue])

  /// What a secret's value is recorded as. A fixed string rather than an omission, so a row
  /// says "this changed and the value is withheld" instead of looking like a change nobody
  /// recorded a value for.
  public static let redacted = AuditValue.string("••••")

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([AuditValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: AuditValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    case .array(let values): try container.encode(values)
    case .object(let values): try container.encode(values)
    }
  }

  /// The value as text, for a CSV cell or a table column. Containers render as JSON.
  public var displayText: String {
    switch self {
    case .string(let value): value
    case .int(let value): String(value)
    case .double(let value): String(value)
    case .bool(let value): value ? "true" : "false"
    case .null: ""
    case .array, .object:
      String(decoding: (try? AuditJSON.encode(self)) ?? Data(), as: UTF8.self)
    }
  }
}

/// The one JSON encoder every audit surface uses, so the row, the CSV cell and the syslog
/// body spell the same document the same way.
///
/// Sorted keys, no pretty printing and no escaped slashes. Sorted keys are what makes two
/// renderings of one record byte-identical, which is what a test compares and what a receiver
/// hashing for deduplication needs.
public enum AuditJSON {
  public static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
  }
}

/// How the thing turned out.
public enum AuditOutcome: String, Sendable, Hashable, Codable, CaseIterable {
  /// It happened.
  case success
  /// It was attempted and did not happen: a send that Messages refused, a receiver that
  /// would not accept a forwarded record.
  case failure
  /// It was refused on purpose: a wrong password, a blocked client, a missing scope.
  case denied
}

/// How much a record deserves attention, in the four steps syslog receivers route on.
///
/// Fewer steps than `BBCore.Severity` on purpose: an audit record is never a success toast,
/// and `error` and `critical` collapse into one because an auditor filters for "look at this
/// now" and nothing finer.
public enum AuditSeverity: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
  /// Ordinary business: a request served, a setting saved.
  case info
  /// Worth noticing: a service started or stopped, a client blocked.
  case notice
  /// Something failed or was refused.
  case warning
  /// Something a person should act on now: the audit log itself stopped forwarding.
  case critical

  private var rank: Int {
    switch self {
    case .info: 0
    case .notice: 1
    case .warning: 2
    case .critical: 3
    }
  }

  public static func < (lhs: AuditSeverity, rhs: AuditSeverity) -> Bool { lhs.rank < rhs.rank }

  /// The RFC 5424 severity code: `critical` is 2, `warning` 4, `notice` 5 and `info` 6.
  public var syslogCode: Int {
    switch self {
    case .critical: 2
    case .warning: 4
    case .notice: 5
    case .info: 6
    }
  }
}

/// What a record is about: a setting, a service, a client address, a webhook.
public struct AuditSubject: Sendable, Hashable, Codable {
  /// A short stable noun: `setting`, `service`, `client`, `webhook`, `scheduled_message`,
  /// `route`. Documented per kind in `docs/AUDIT_LOG.md`.
  public let kind: String
  /// The identifier within that kind: a storage key, a service identifier, an IP address,
  /// a row id.
  public let id: String

  public init(kind: String, id: String) {
    self.kind = kind
    self.id = id
  }

  public static func setting(_ key: String) -> AuditSubject { .init(kind: "setting", id: key) }
  public static func service(_ id: String) -> AuditSubject { .init(kind: "service", id: id) }
  public static func client(_ address: String) -> AuditSubject {
    .init(kind: "client", id: address)
  }
  public static func route(_ template: String) -> AuditSubject {
    .init(kind: "route", id: template)
  }
  public static func webhook(_ id: Int64) -> AuditSubject { .init(kind: "webhook", id: "\(id)") }
  public static func scheduledMessage(_ id: Int64) -> AuditSubject {
    .init(kind: "scheduled_message", id: "\(id)")
  }
  public static func allowlistEntry(_ cidr: String) -> AuditSubject {
    .init(kind: "allowlist_entry", id: cidr)
  }
}

/// One audited occurrence.
public struct AuditEvent: Sendable, Hashable, Identifiable {

  /// The version of this envelope. Bumped only when a field is renamed or removed, which is
  /// a change every stored row and every receiver has to know about; adding a field is not.
  public static let schemaVersion = 1

  /// The row's identifier once stored, and the identity a list keys on. Nil for a record
  /// that has not reached the database.
  public var id: Int64?
  /// Stable across every surface: the same event exported twice carries the same UUID, which
  /// is what a receiver deduplicates on.
  public let uuid: UUID
  public let occurredAt: Date
  public let kind: AuditEventKind
  public var category: AuditCategory { kind.category }
  public let outcome: AuditOutcome
  public let severity: AuditSeverity
  public let actor: AuditActor
  public let source: AuditSource
  /// Joins a transport record to the domain records written while it was handled.
  public let requestID: String?
  /// The route template of the request this happened under, when there was one.
  public let route: String?
  public let subject: AuditSubject?
  /// One sentence for a person. Never carries content, an address other than a client's, or
  /// a secret: it is rendered on the page and forwarded as-is.
  public let summary: String
  /// The kind-specific fields; see `AuditEventKind.metadataFields`.
  public let metadata: [String: AuditValue]

  /// - Parameters:
  ///   - actor: Defaults to the actor of the work in flight (`AuditContext.effective`).
  ///   - source: Defaults to the source the context carries, else the one implied by the
  ///     actor: a client arrived over HTTP, the operator used the app, the system is the
  ///     server.
  ///   - requestID: Defaults to the request in flight, so a domain record written inside a
  ///     request joins to its transport record without the emitter knowing there was one.
  public init(
    kind: AuditEventKind,
    outcome: AuditOutcome = .success,
    severity: AuditSeverity? = nil,
    actor: AuditActor? = nil,
    source: AuditSource? = nil,
    requestID: String? = nil,
    route: String? = nil,
    subject: AuditSubject? = nil,
    summary: String,
    metadata: [String: AuditValue] = [:],
    occurredAt: Date = Date(),
    uuid: UUID = UUID(),
    id: Int64? = nil
  ) {
    let context = AuditContext.current
    let resolvedActor = actor ?? context?.actor ?? AuditContext.fallbackActor
    self.id = id
    self.uuid = uuid
    self.occurredAt = occurredAt
    self.kind = kind
    self.outcome = outcome
    self.severity = severity ?? kind.defaultSeverity(for: outcome)
    self.actor = resolvedActor
    self.source = source ?? context?.source ?? AuditSource.implied(by: resolvedActor)
    self.requestID = requestID ?? context?.requestID
    self.route = route ?? context?.route
    self.subject = subject
    self.summary = summary
    self.metadata = metadata
  }

  /// The canonical document: what syslog carries as its message and what a CSV's `metadata`
  /// column is a fragment of. Every key is documented in `docs/AUDIT_LOG.md`.
  ///
  /// - Parameter hostname: The machine, for a document read away from it. Nil omits the key.
  public func document(hostname: String? = nil) -> [String: AuditValue] {
    var fields: [String: AuditValue] = [
      "schema_version": .int(Self.schemaVersion),
      "uuid": .string(uuid.uuidString.lowercased()),
      "occurred_at": .string(AuditTimestamp.string(from: occurredAt)),
      "category": .string(category.rawValue),
      "kind": .string(kind.rawValue),
      "outcome": .string(outcome.rawValue),
      "severity": .string(severity.rawValue),
      "actor": .object([
        "kind": .string(actor.kind),
        "id": actor.identifier.map(AuditValue.string) ?? .null,
      ]),
      "source": .string(source.rawValue),
      "request_id": requestID.map(AuditValue.string) ?? .null,
      "route": route.map(AuditValue.string) ?? .null,
      "subject": subject.map { .object(["kind": .string($0.kind), "id": .string($0.id)]) }
        ?? .null,
      "summary": .string(summary),
      "metadata": .object(metadata),
    ]
    if let id { fields["id"] = .int(Int(id)) }
    if let hostname { fields["host"] = .string(hostname) }
    return fields
  }

  /// `document(hostname:)` as JSON bytes.
  public func json(hostname: String? = nil) throws -> Data {
    try AuditJSON.encode(AuditValue.object(document(hostname: hostname)))
  }
}

/// The one timestamp spelling every audit surface uses: RFC 3339, UTC, millisecond precision.
///
/// UTC rather than the Mac's zone because a record read in a SIEM beside records from other
/// machines has to sort against them, and a `Z` is unambiguous where `-07:00` invites a
/// receiver to convert twice.
public enum AuditTimestamp {
  private static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  public static func string(from date: Date) -> String {
    formatter.string(from: date)
  }

  public static func date(from string: String) -> Date? {
    formatter.date(from: string)
  }
}
