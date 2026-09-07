//  WebhookRepository
//  The only path to the `webhook` table.
//
//  This table had two owners reading it two different ways: a `PersistableRecord` in
//  `AdminInterface` for the CRUD the API exposes, and a raw `Row.fetchAll` in `AppContext`
//  for the delivery path. Two decoders for one table is one place for them to disagree, and
//  the `events` column — a JSON array stored as text — is exactly the sort of column they
//  disagree about: the raw reader parsed it into names and the record left it as a string.
//
//  Both now go through here. Parsing `events` happens once, in `subscribedEvents`.

import BBEvents
import BBPersistence
import BBSerialization
import Foundation
import GRDB

/// A registered webhook endpoint.
public struct Webhook: Sendable, Codable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "webhook"

  public var id: Int64?
  public var url: String
  /// A JSON array of event names, stored as text. `["*"]` means everything, which is what a
  /// client that sends no list gets.
  public var events: String
  public var createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id, url, events
    case createdAt = "created_at"
  }

  /// The `events` column decoded. The one place that column is interpreted.
  public var subscribedEvents: [String] {
    (try? JSONValue.parse(Data(events.utf8)))?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  public var json: JSONValue {
    .object([
      "id": .int64(id ?? 0),
      "url": .string(url),
      "events": (try? JSONValue.parse(Data(events.utf8))) ?? .array([]),
      "created": .int64(Int64(createdAt.timeIntervalSince1970 * 1000)),
    ])
  }

  /// Event names as the stored JSON array. An empty list means everything, which is what a
  /// client that sends no list gets.
  public static func encode(events: [String]) -> String {
    guard !events.isEmpty else { return "[\"*\"]" }
    let data = (try? JSONValue.array(events.map(JSONValue.string)).serialize()) ?? Data()
    let encoded = String(decoding: data, as: UTF8.self)
    return encoded.isEmpty ? "[\"*\"]" : encoded
  }
}

public struct WebhookRepository: Sendable {

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func all() async throws -> [Webhook] {
    try await database.read { db in
      try Webhook.order(Column("id")).fetchAll(db)
    }
  }

  /// The delivery path's view: endpoints with their subscriptions already decoded.
  public func targets() async throws -> [WebhookTarget] {
    // Mapped INSIDE the read closure. GRDB's `Row` is not Sendable — it borrows the
    // statement's storage — so carrying rows across the boundary and reading them
    // afterwards is a use-after-free the compiler is right to reject.
    try await database.read { db in
      try Webhook.order(Column("id")).fetchAll(db).map {
        WebhookTarget(id: $0.id ?? 0, url: $0.url, events: $0.subscribedEvents)
      }
    }
  }

  /// Registers an endpoint, or updates the one already on that URL.
  ///
  /// Upserted on the unique URL rather than inserted: registering the same webhook twice is
  /// what a client does after a reinstall, and a constraint failure there reads as "the
  /// server is broken" rather than "you already have this".
  public func upsert(url: String, events: [String]) async throws -> Webhook {
    let encoded = Webhook.encode(events: events)
    return try await database.write { db in
      var record = Webhook(
        id: try Webhook.filter(Column("url") == url).fetchOne(db)?.id,
        url: url,
        events: encoded,
        createdAt: Date()
      )
      try record.save(db)
      if record.id == nil { record.id = db.lastInsertedRowID }
      return record
    }
  }

  /// Changes an endpoint's URL, its subscriptions, or both.
  ///
  /// Separate from `upsert` even though that one upserts, because the upsert is keyed on
  /// the URL: editing an endpoint's address through it would leave the old address
  /// registered and still being called, which is the opposite of what editing it means.
  public func update(id: Int64, url: String?, events: [String]?) async throws -> Webhook {
    let encoded = events.map(Webhook.encode(events:))
    return try await database.write { db in
      guard var record = try Webhook.filter(Column("id") == id).fetchOne(db) else {
        throw InterfaceError.notFound(ReferenceMessages.webhookNotFound)
      }
      if let url {
        // The URL column is unique, so moving one endpoint onto another's address would
        // fail at the constraint with nothing explaining which of the two rows was the
        // problem.
        let existing = try Webhook.filter(Column("url") == url).fetchOne(db)
        if let existing, existing.id != id {
          throw InterfaceError.invalidRequest(
            "another webhook is already registered for that URL")
        }
        record.url = url
      }
      if let encoded { record.events = encoded }
      try record.update(db)
      return record
    }
  }

  public func delete(id: Int64) async throws {
    let deleted = try await database.write { db in
      try Webhook.filter(Column("id") == id).deleteAll(db)
    }
    guard deleted > 0 else { throw InterfaceError.notFound(ReferenceMessages.webhookNotFound) }
  }
}
