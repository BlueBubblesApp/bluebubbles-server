//  DeviceRepository
//  The only path to the `device` table.
//
//  There was no owner for this table. An HTTP handler ran the INSERT, and the composition
//  container ran the DELETEs and the SELECT — four statements in two layers, none of which
//  knew about the others, and no type describing what a row is. The `supported_codecs` and
//  `public_key` columns have been in the schema since `createDevices` and nothing has ever
//  read them, which is exactly the kind of thing that stays invisible when a table has no
//  owner to look at.
//
//  Repositories in this folder are the boundary the app database did not have: one type per
//  table, every statement inside it, and callers that deal in values.

import BBPersistence
import Foundation
import GRDB

/// A registered push target.
public struct Device: Sendable, Codable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "device"

  public var id: Int64?
  public var name: String
  /// The FCM registration token. Unique, and the key a re-registration upserts on.
  public var identifier: String
  public var lastActive: Date?
  /// Which payload codecs this client advertised. Null means legacy-v1.
  public var supportedCodecs: String?
  public var publicKey: Data?

  enum CodingKeys: String, CodingKey {
    case id, name, identifier
    case lastActive = "last_active_at"
    case supportedCodecs = "supported_codecs"
    case publicKey = "public_key"
  }

  public init(
    id: Int64? = nil,
    name: String,
    identifier: String,
    lastActive: Date? = nil,
    supportedCodecs: String? = nil,
    publicKey: Data? = nil
  ) {
    self.id = id
    self.name = name
    self.identifier = identifier
    self.lastActive = lastActive
    self.supportedCodecs = supportedCodecs
    self.publicKey = publicKey
  }
}

public struct DeviceRepository: Sendable {

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Records a client's push registration.
  ///
  /// Upserted on the token, not inserted. A client re-registers on every launch and after
  /// every FCM token rotation, so a plain insert would fail the unique constraint on the
  /// common path — which reads to the user as "the server rejected my phone".
  ///
  /// Only `name` and `last_active_at` are overwritten on conflict: `supported_codecs` and
  /// `public_key` are negotiated separately and must survive a re-registration that does
  /// not carry them. That targeted conflict clause is why this is hand-written SQL rather
  /// than a record upsert, which would blank both.
  ///
  /// The column is `last_active_at`, not `last_active`. `createDevices` creates the short
  /// name and `normaliseTimestampColumnNames` — which runs after every contributor — renames
  /// it, so the short name exists in no database this code will ever open. Spelling it here
  /// made every push registration fail at prepare time, and nothing caught it because
  /// nothing called this method.
  public func register(name: String, identifier: String, at moment: Date = Date()) async throws {
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO device (name, identifier, last_active_at)
          VALUES (?, ?, ?)
          ON CONFLICT(identifier) DO UPDATE SET
              name = excluded.name,
              last_active_at = excluded.last_active_at
          """,
        arguments: [name, identifier, moment]
      )
    }
  }

  /// Every registered push token.
  ///
  /// Read fresh on each notification rather than cached: a client registers on launch and
  /// after every FCM token rotation, and a cache would send to the old token until whenever
  /// it was next invalidated.
  public func tokens() async throws -> [String] {
    try await database.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM device")
    }
  }

  /// Removes devices FCM reported as unregistered.
  ///
  /// - Returns: how many rows were removed.
  @discardableResult
  public func prune(tokens: [String]) async throws -> Int {
    guard !tokens.isEmpty else { return 0 }
    return try await database.write { db in
      try Device.filter(tokens.contains(Column("identifier"))).deleteAll(db)
    }
  }

  /// Drops every registered device.
  ///
  /// Called when the Firebase project changes. An FCM token is issued BY a project and is
  /// meaningless to any other, so credentials for a new project make the whole list dead
  /// weight — every send fails with `registration-token-not-registered`, which is the one
  /// error the sender deliberately does not report.
  public func deleteAll() async throws {
    _ = try await database.write { db in
      try Device.deleteAll(db)
    }
  }
}
