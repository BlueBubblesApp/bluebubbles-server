//  DeviceRepository
//  The only path to the `device` table.
//
//  Repositories in this folder are the app database's boundary: one type per table, every
//  statement inside it, and callers that deal in values. A table with statements spread
//  across layers has no type describing what a row is, and columns nothing reads stay
//  invisible.

import BBPersistence
import Foundation
import GRDB
import Logging

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
  private let logger: Logger

  public init(database: AppDatabase, logger: Logger = Logger(label: "bluebubbles.devices")) {
    self.database = database
    self.logger = logger
  }

  /// Records a client's push registration.
  ///
  /// Upserted on the token, not inserted. A client re-registers on every launch and after
  /// every FCM token rotation, so a plain insert would fail the unique constraint on the
  /// common path, which reads to the user as "the server rejected my phone".
  ///
  /// Only `name` and `last_active_at` are overwritten on conflict: `supported_codecs` and
  /// `public_key` are negotiated separately and must survive a re-registration that does
  /// not carry them. That targeted conflict clause is why this is hand-written SQL rather
  /// than a record upsert, which would blank both.
  ///
  /// The column is `last_active_at`, not `last_active`. `createDevices` creates the short
  /// name and `normaliseTimestampColumnNames` (which runs after every contributor) renames
  /// it, so the short name exists in no database this code will ever open, and spelling it
  /// here fails at prepare time.
  public func register(name: String, identifier: String, at moment: Date = Date()) async throws {
    let isNew = try await database.write { db in
      let known =
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM device WHERE identifier = ?", arguments: [identifier]
        ) ?? 0
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
      return known == 0
    }
    // Neither argument can go in the line. The name is the one the person gave their
    // phone and is routinely their own ("Zach's iPhone"); the identifier is the push
    // token, which is a credential. So the line says that a registration happened and
    // whether it was the first, and the `device` table is where you look up which one.
    logger.info(isNew ? "Registered a new push device" : "Push device re-registered")
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

  /// Every registered device, whole.
  ///
  /// Ordered by registration, so the list a screen draws does not reshuffle when a client
  /// re-registers and moves its `last_active_at`. `tokens()` stays separate and stays the
  /// delivery path's call: sending wants one column and this does not.
  public func all() async throws -> [Device] {
    try await database.read { db in
      try Device.order(Column("id")).fetchAll(db)
    }
  }

  /// The table, now and after every change to it.
  ///
  /// Whichever path wrote it — this process's API, a client registering over HTTP, a prune
  /// after FCM rejected a token — the follower sees the new list, so a screen showing it
  /// never has to re-read on a timer. The first element is the current table. Throws only
  /// if the database itself does, which a follower reports the way a failed `all()` is
  /// reported.
  ///
  /// A plain stream rather than GRDB's own sequence type, so a caller follows the table
  /// without importing GRDB: the same shape `WebhookRepository.changes()` has, and for the
  /// same reason.
  public func changes() -> AsyncThrowingStream<[Device], any Error> {
    let observation = database.observe { db in
      try Device.order(Column("id")).fetchAll(db)
    }
    return AsyncThrowingStream { continuation in
      let forwarding = Task {
        do {
          for try await rows in observation { continuation.yield(rows) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in forwarding.cancel() }
    }
  }

  /// Removes one registration.
  ///
  /// By row id rather than by token, because the token is the thing a screen should not
  /// have to hold in order to act on a row. Removing a live device is not permanent in the
  /// way it looks: the client re-registers on its next launch or token rotation, and the
  /// row comes back.
  ///
  /// - Returns: whether a row was actually removed, so a caller can tell "gone" from
  ///   "was already gone" rather than reporting success for a row a concurrent prune took.
  @discardableResult
  public func remove(id: Int64) async throws -> Bool {
    try await database.write { db in
      try Device.deleteOne(db, key: id)
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
  /// weight: every send fails with `registration-token-not-registered`, which is the one
  /// error the sender deliberately does not report.
  public func deleteAll() async throws {
    _ = try await database.write { db in
      try Device.deleteAll(db)
    }
  }
}
