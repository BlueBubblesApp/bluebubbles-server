//  ServerInterface
//  Server administration: alerts, statistics, webhooks, backups, scheduled messages.
//
//  The part of the surface that is about the server rather than about Messages. It is also
//  the part the SwiftUI app leans on hardest — the settings window is almost entirely made
//  of these calls, and in the current implementation each one is a hand-written IPC channel.

import BBCore
import BBDiagnostics
import BBIMessage
import BBPersistence
import BBSerialization
import BBSettings
import Foundation
import GRDB
import Logging

public struct ServerInterface: Sendable {

  private let database: AppDatabase
  private let alerts: AlertCenter
  private let settings: SettingsStore
  private let messages: MessageRepository?
  private let logger: Logger

  public init(
    database: AppDatabase,
    alerts: AlertCenter,
    settings: SettingsStore,
    messages: MessageRepository?,
    logger: Logger = Logger(label: "bluebubbles.interface.server")
  ) {
    self.database = database
    self.alerts = alerts
    self.settings = settings
    self.messages = messages
    self.logger = logger
  }

  // MARK: - Alerts

  /// `GET /api/v1/server/alert` — the Node `alert` row, and nothing else.
  ///
  /// Six keys, an integer `id`, `type` in the reference's three-value vocabulary, `value` as
  /// `"title: body"`, and ISO dates. There is no `?fields=extended` here any more: extra
  /// fields are new surface, and new surface lives in v2 (`.claude/docs/api.md`). Keeping a
  /// query parameter that reshapes a v1 response would be exactly the "additive is not
  /// invisible" problem the version split exists to end.
  public func alerts(limit: Int = 10) async -> [JSONValue] {
    await alerts.all(limit: limit).map(Self.alertJSON)
  }

  /// `GET /api/v2/server/alert` — everything the alert actually carries.
  ///
  /// The v1 row throws away most of an alert: `value` flattens a title and a body into one
  /// string, `type` folds five severities into three, and the diagnostics, the remedy
  /// actions and the occurrence count have nowhere to go at all. This is the full alert
  /// shape, and the one the app uses in process.
  ///
  /// `id` is the SAME integer v1 reports, deliberately. The two versions describe the same
  /// alert, and a client reading v2 and marking read over either endpoint must not have to
  /// translate between identity schemes.
  public func alertsV2(limit: Int = 100) async -> [JSONValue] {
    await alerts.all(limit: limit).map(Self.alertJSONV2)
  }

  /// The v1 projection, as a pure function of one alert.
  ///
  /// Static and public so a test can pin the exact key set without standing up a database, a
  /// settings store and a message repository. The key set IS the contract here, and a test
  /// that cannot reach it cheaply is a test nobody writes.
  public static func alertJSON(_ alert: UserAlert) -> JSONValue {
    .object([
      // An INTEGER. The reference's `alert.id` is an autoincrement primary key, and a client
      // doing `parseInt(id)` on a UUID gets NaN.
      "id": .int(alert.sequence),
      "type": .string(alert.legacyType),
      "value": .string(alert.legacyValue),
      "isRead": .bool(alert.readAt != nil),
      // ISO 8601, not epoch milliseconds — this route returns a TypeORM entity whose
      // `Date` columns JSON.stringify into strings. See `WireDate`.
      "created": .string(WireDate.iso(alert.createdAt)),
      "updated": .string(WireDate.iso(alert.lastUpdatedAt)),
    ])
  }

  /// The v2 projection.
  public static func alertJSONV2(_ alert: UserAlert) -> JSONValue {
    var object: [String: JSONValue] = [
      "id": .int(alert.sequence),
      // The REAL severity, not the reference's folded three. A client that wants to
      // distinguish an error from a critical can, which v1 cannot express.
      "severity": .string(alert.severity.rawValue),
      // Separate, rather than concatenated into one `value` string a client has to
      // split on ": " — which breaks the moment a title contains one.
      "title": .string(alert.title),
      "body": .string(alert.body),
      "source": .string(alert.source),
      "isRead": .bool(alert.readAt != nil),
      "created": .string(WireDate.iso(alert.createdAt)),
      "updated": .string(WireDate.iso(alert.lastUpdatedAt)),
      // Repeated raises coalesce, so one row can stand for many occurrences. v1 has
      // nowhere to say that and simply looks like a single event.
      "occurrenceCount": .int(alert.occurrenceCount),
      "lastOccurredAt": .string(WireDate.iso(alert.lastOccurredAt)),
      // The remedy travels with the problem. Stable wire names, not Swift
      // descriptions.
      "actions": .array(alert.actions.map { .string($0.wireName) }),
    ]
    object["readAt"] = alert.readAt.map { .string(WireDate.iso($0)) } ?? .null
    object["dedupeKey"] = alert.dedupeKey.map(JSONValue.string) ?? .null
    // The REDACTED report, never the raw context. Anything sourced from a setting marked
    // `isSecret` renders as bullets, and this route is reachable by any authenticated
    // client — including one on a tunnel.
    object["diagnostics"] = alert.diagnostics.map { .string($0.redactedReport()) } ?? .null
    return .object(object)
  }

  /// Marks the named alerts read.
  ///
  /// An empty list marks NOTHING, deliberately. Treating it as "all" reads as a convenience
  /// and behaves as a trap: any caller whose ids fail to parse would silently clear the
  /// user's entire notification list instead of erroring. Marking everything read is
  /// `AlertCenter.markAllRead`, which the app calls directly and no route reaches.
  public func markAlertsRead(ids: [String]) async {
    guard !ids.isEmpty else { return }
    // Sequence numbers are what clients hold, on both versions. UUIDs are still accepted
    // because an older build emitted them, and a client that cached one should not silently
    // stop being able to mark it read.
    await alerts.markRead(sequences: ids.compactMap(Int.init))
    let uuids = ids.compactMap(UUID.init(uuidString:))
    if !uuids.isEmpty { await alerts.markRead(uuids) }
  }

  // MARK: - Statistics

  /// What the database holds, as four counts.
  public struct Totals: Sendable, Equatable {
    public let handles: Int
    public let messages: Int
    public let chats: Int
    public let attachments: Int
  }

  /// The wire shape, for the HTTP routes.
  public func totals() async throws -> JSONValue {
    let counts = try await counts()
    return .object([
      "handles": .int(counts.handles),
      "messages": .int(counts.messages),
      "chats": .int(counts.chats),
      "attachments": .int(counts.attachments),
    ])
  }

  /// The same counts as VALUES, for callers in this process. The home screen read these
  /// back out of the dictionary by string key, which meant a renamed key would have shown
  /// an em dash rather than failing to build.
  public func counts() async throws -> Totals {
    guard let messages else {
      throw InterfaceError.unavailable("the iMessage database is not readable")
    }
    // Four independent counts, run concurrently. Sequentially this is four full table
    // scans one after another, and on a large database that is the difference between a
    // responsive stats page and a visibly stalled one.
    async let handles = messages.handleCount()
    async let chats = messages.chatCount()
    async let all = messages.messageCount()
    async let attachments = messages.attachmentCount()

    return Totals(
      handles: try await handles,
      messages: try await all,
      chats: try await chats,
      attachments: try await attachments
    )
  }

  // MARK: - Webhooks
  //
  // Storage, the record type and the `events` encoding all live in `WebhookRepository`.
  // What stays here is the part that is this layer's job: validating what a client sent,
  // and projecting a row into the wire shape.

  private var webhookStore: WebhookRepository { WebhookRepository(database: database) }

  /// The wire shape, for the HTTP routes.
  public func webhooks() async throws -> [JSONValue] {
    try await webhookStore.all().map(\.json)
  }

  /// The same endpoints as VALUES, for callers in this process.
  ///
  /// The app runs in the same process as the server and has the record type available, so
  /// handing it JSON meant every view re-derived the fields by subscript —
  /// `hook["id"]?.intValue ?? 0` — which is the untyped boundary an in-process UI does not
  /// have to pay for. The JSON projection above stays because the wire contract is exactly
  /// what it describes.
  public func webhookList() async throws -> [Webhook] {
    try await webhookStore.all()
  }

  public func createWebhook(url: String, events: [String]) async throws -> JSONValue {
    try Self.validate(url: url)
    return try await webhookStore.upsert(url: url, events: events).json
  }

  public func updateWebhook(id: Int64, url: String?, events: [String]?) async throws -> JSONValue {
    if let url { try Self.validate(url: url) }
    return try await webhookStore.update(id: id, url: url, events: events).json
  }

  public func deleteWebhook(id: Int64) async throws {
    try await webhookStore.delete(id: id)
  }

  private static func validate(url: String) throws {
    guard let parsed = URL(string: url), parsed.scheme == "http" || parsed.scheme == "https" else {
      throw InterfaceError.invalidRequest("`url` must be an http or https URL")
    }
  }

  // MARK: - Backups
  //
  // Storage and the record type live in `BackupRepository`. What stays here is validation
  // and the wire projection.

  private var backupStore: BackupRepository { BackupRepository(database: database) }

  public enum BackupKind: String, Sendable {
    case theme
    case settings
  }

  public func backups(kind: BackupKind) async throws -> JSONValue {
    let rows = try await backupStore.all(kind: kind.rawValue)
    // An array of the stored documents. A backup whose bytes are no longer valid JSON is
    // skipped rather than failing the whole listing — one corrupt theme should not make
    // a client unable to load any of them.
    return .array(
      rows.compactMap { row in
        guard let value = try? JSONValue.parse(row.payload) else {
          logger.warning(
            "Skipping unreadable backup",
            metadata: [
              "kind": .string(row.kind), "name": .string(row.name),
            ])
          return nil
        }
        return value
      })
  }

  public func saveBackup(kind: BackupKind, name: String, payload: JSONValue) async throws {
    guard !name.isEmpty else { throw InterfaceError.invalidRequest("`name` is required") }
    try await backupStore.save(kind: kind.rawValue, name: name, payload: try payload.serialize())
  }

  /// Deletes one backup by name, or every backup of a kind when `name` is nil.
  public func deleteBackup(kind: BackupKind, name: String?) async throws {
    let deleted = try await backupStore.delete(kind: kind.rawValue, name: name)
    guard deleted > 0 else {
      throw InterfaceError.notFound(
        name.map { "no \(kind.rawValue) named \($0)" }
          ?? "no \(kind.rawValue) backups")
    }
  }
}
