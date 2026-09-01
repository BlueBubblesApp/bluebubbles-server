//  UserAlert
//  A notification a person actually sees. Deliberately separate from logging.
//
//  In the current server, Server().log(msg, "error") writes a log AND creates an alert row
//  AND bumps the dock badge (index.ts:269-297), so every internal error becomes a
//  user-facing notification carrying nothing but a string. These are now two systems:
//  swift-log never produces a user-visible item, and alerts are raised explicitly.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import Foundation

/// Structured debugging payload attached to an alert, revealed on demand in the UI.
///
/// This is what turns "something went wrong" into something a maintainer can act on without
/// asking the reporter to reproduce it.
public struct Diagnostics: Sendable {
  /// Stable machine code, e.g. `"helper.not_connected"`. Searchable across issues.
  public let code: String?
  public let domain: String?
  public let underlyingDescription: String?
  /// Symbolicated call stack captured at raise time.
  public let stackTrace: [String]?
  /// Typed context. `.secret` values render redacted everywhere, including exports.
  public let context: [String: DiagnosticValue]
  /// Recent log lines from the raising source, so the alert carries its own surroundings.
  public let logExcerpt: [String]?

  public init(
    code: String? = nil,
    domain: String? = nil,
    underlyingDescription: String? = nil,
    stackTrace: [String]? = nil,
    context: [String: DiagnosticValue] = [:],
    logExcerpt: [String]? = nil
  ) {
    self.code = code
    self.domain = domain
    self.underlyingDescription = underlyingDescription
    self.stackTrace = stackTrace
    self.context = context
    self.logExcerpt = logExcerpt
  }

  /// The paste-ready bundle behind the UI's "Copy Diagnostic Report" button — the artifact
  /// users currently assemble by hand for Discord and GitHub issues.
  ///
  /// Never contains a `.secret` value; redaction happens at the `DiagnosticValue` level so
  /// it cannot be forgotten here.
  public func redactedReport() -> String {
    var lines: [String] = []
    if let code { lines.append("code: \(code)") }
    if let domain { lines.append("domain: \(domain)") }
    if let underlyingDescription { lines.append("underlying: \(underlyingDescription)") }
    if !context.isEmpty {
      lines.append("context:")
      for key in context.keys.sorted() {
        lines.append("  \(key): \(context[key]!.redactedDescription)")
      }
    }
    if let stackTrace, !stackTrace.isEmpty {
      lines.append("stack:")
      lines.append(contentsOf: stackTrace.map { "  \($0)" })
    }
    if let logExcerpt, !logExcerpt.isEmpty {
      lines.append("log:")
      lines.append(contentsOf: logExcerpt.map { "  \($0)" })
    }
    return lines.joined(separator: "\n")
  }
}

/// Something the alert offers to do about itself, so the remedy travels with the problem.
public enum AlertAction: Sendable, Equatable {
  case openSettings(section: String)
  case openLogs
  case retry(service: String)
  case openURL(URL)
  case relaunch
  /// Stop and start the server in place — no app relaunch.
  ///
  /// Distinct from `.relaunch`, which restarts the whole application. Some settings are read
  /// once while the server is being assembled and configure objects built before any service
  /// exists; a service restart cannot pick those up, but a server restart rebuilds them.
  case restartServer
  /// Offered on a rate-limit block so an accidental lockout is one click to undo,
  /// rather than a hunt through settings. See `docs/AUTH.md`.
  case unblock(address: String)
  /// Opens the page where an external program can be installed or updated.
  ///
  /// Carries the TOOL's id rather than a service's, because the thing needing attention is
  /// the program: which integration page it is reached from is the app's business, and more
  /// than one may declare the same tool.
  case installTool(id: String)

  /// Stable identifier for `?fields=extended`, so a client can recognise an action without
  /// parsing a Swift description that changes whenever a case gains a payload.
  ///
  /// Switched exhaustively with no `default`: a new case must be named here rather than
  /// silently reaching the wire as something unrecognisable.
  public var wireName: String {
    switch self {
    case .openSettings: "open-settings"
    case .openLogs: "open-logs"
    case .retry: "retry"
    case .openURL: "open-url"
    case .relaunch: "relaunch"
    case .restartServer: "restart-server"
    case .unblock: "unblock"
    case .installTool: "install-tool"
    }
  }
}

public struct UserAlert: Identifiable, Sendable {
  /// Internal identity: stable, collision-free, and what SwiftUI lists and the dedupe index
  /// key on. NOT what goes on the wire — see `sequence`.
  public let id: UUID
  /// The identifier CLIENTS see, on both `/api/v1/server/alert` and `/api/v2/server/alert`.
  ///
  /// An integer because the reference's `alert.id` is an autoincrement primary key, and a
  /// client doing `parseInt(id)` on a UUID gets NaN. Assigned by `AlertCenter` on raise —
  /// 0 means "not yet raised", which is the state of an alert a caller has built and not
  /// handed over.
  ///
  /// Deliberately the same value in v1 and v2: the two versions describe the same alert, and
  /// a client cross-referencing them must not have to translate between two identity
  /// schemes.
  ///
  /// With an `AlertStoring` attached this is the stored row's autoincrement id — the same
  /// thing the reference's `alert.id` is — so it keeps counting up across restarts and a
  /// client's stale id never addresses a different alert. Without one it restarts at 1 with
  /// the process, which is all an in-memory centre can offer.
  public internal(set) var sequence: Int = 0
  public let severity: Severity
  /// Short and human: "Cloudflare tunnel disconnected". Not a code, not a stack frame.
  public let title: String
  /// One or two actionable sentences.
  public let body: String
  public let source: String
  public let createdAt: Date
  public var readAt: Date?
  /// Set only by a caller that wants to record a dismissal alongside the alert.
  ///
  /// `AlertCenter.dismiss` REMOVES the alert rather than stamping this, so nothing inside
  /// the centre ever reads it. Kept because `UserAlert` is also the shape a caller can
  /// build and hold on its own; it is not part of the centre's own state model.
  public var dismissedAt: Date?

  public let diagnostics: Diagnostics?
  public let actions: [AlertAction]

  /// Whether this alert is still true after a restart.
  ///
  /// A durable alert states a FACT — a Keychain that would not unlock, a permission the user
  /// revoked, a downloaded binary whose signature did not match. Restarting the server does
  /// not make any of those untrue, so it comes back unread.
  ///
  /// A transient one describes a LIVE CONDITION — no helper connected, the tunnel is down,
  /// this port is already in use. Those are re-derived the moment the server starts again,
  /// so presenting the old one as current would show a problem that may well have cleared.
  /// Transient alerts are still stored, because their history and occurrence counts are
  /// worth having; they are just restored already-read rather than clamouring.
  public var isDurable: Bool = true

  /// Repeated raises sharing a key coalesce instead of spamming. A flapping proxy becomes
  /// one row reading "occurred 47 times" rather than 47 rows.
  public let dedupeKey: String?
  public var occurrenceCount: Int
  public var lastOccurredAt: Date

  public init(
    id: UUID = UUID(),
    severity: Severity,
    title: String,
    body: String,
    source: String,
    createdAt: Date = Date(),
    diagnostics: Diagnostics? = nil,
    actions: [AlertAction] = [],
    dedupeKey: String? = nil,
    isDurable: Bool = true
  ) {
    self.isDurable = isDurable
    self.id = id
    self.severity = severity
    self.title = title
    self.body = body
    self.source = source
    self.createdAt = createdAt
    self.diagnostics = diagnostics
    self.actions = actions
    self.dedupeKey = dedupeKey
    self.occurrenceCount = 1
    self.lastOccurredAt = createdAt
  }

  /// Rebuilds an alert from storage.
  ///
  /// The only way to set `sequence` from outside this module, and deliberately narrow:
  /// `internal(set)` exists so nothing but the alert centre invents a sequence number, and
  /// a store is not inventing one — it is handing back the number the row already has.
  ///
  /// `actions` are not a parameter. An action is a live instruction into a running server
  /// ("open Settings", "restart"), so the set stored a week ago belongs to a process that no
  /// longer exists; a restored alert carries its text and its history, not its buttons.
  public static func restored(
    id: UUID,
    sequence: Int,
    severity: Severity,
    title: String,
    body: String,
    source: String,
    createdAt: Date,
    lastOccurredAt: Date,
    occurrenceCount: Int,
    readAt: Date?,
    dedupeKey: String?,
    isDurable: Bool,
    diagnostics: Diagnostics?
  ) -> UserAlert {
    var alert = UserAlert(
      id: id, severity: severity, title: title, body: body, source: source,
      createdAt: createdAt, diagnostics: diagnostics, actions: [],
      dedupeKey: dedupeKey, isDurable: isDurable
    )
    alert.sequence = sequence
    alert.occurrenceCount = occurrenceCount
    alert.lastOccurredAt = lastOccurredAt
    alert.readAt = readAt
    return alert
  }

  /// Legacy wire shape for `GET /api/v1/server/alert`, which returns
  /// `{id, type, value, isRead, created, updated}`.
  ///
  /// The default response keeps exactly those keys with no additions — the compatibility
  /// contract puts a strict client parser ahead of convenience. Structured fields are
  /// served only when a client asks via `?fields=extended`.
  public var legacyValue: String { "\(title): \(body)" }

  /// The `type` string a Node server would have written.
  ///
  /// Node only ever creates alerts with `"error"`, `"warn"` or `"info"`
  /// (`index.ts:269-297`, `:1289`), and clients string-match those values. `Severity` has
  /// five cases, so two of them have to fold: `.warning` spells itself `"warn"` — NOT
  /// `"warning"`, which is what the raw value gives and what no client recognises — and
  /// `.critical` reports as `"error"`, since a client that hides unknown types would
  /// otherwise drop the most severe alerts the server can raise.
  ///
  /// `.success` passes through: the `alert` entity documents it as a legal value even
  /// though `Server().log` never produces one.
  public var legacyType: String {
    switch severity {
    case .info: "info"
    case .success: "success"
    case .warning: "warn"
    case .error, .critical: "error"
    }
  }

  /// `updated` on the Node row, which TypeORM stamps on every write.
  ///
  /// The only write after creation is the read stamp and the dedupe bump, so the newest of
  /// those is the equivalent. `created` when neither has happened, matching a row that has
  /// never been touched.
  public var lastUpdatedAt: Date {
    max(lastOccurredAt, readAt ?? createdAt)
  }
}

/// Raising is always explicit. There is no path from `logger.error(...)` to a `UserAlert`.
public protocol AlertRaising: Sendable {
  func raise(_ alert: UserAlert) async
  func raise(_ error: any BBError, actions: [AlertAction]) async
}
