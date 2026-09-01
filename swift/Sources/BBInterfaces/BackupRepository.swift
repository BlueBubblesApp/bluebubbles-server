//  BackupRepository
//  The only path to the `backup` table.
//
//  This one already had a single owner, so unlike the other three there was no split to
//  repair. It moved anyway, because the rule is worth being able to state without
//  exceptions: every table in the app database is owned by a repository in this folder, and
//  a table's statements are not somewhere else because that is where they happened to be
//  written first.

import BBPersistence
import Foundation
import GRDB

/// An opaque client blob. The server stores and returns these and never parses them, which
/// is what keeps a client-side format change from needing a server release.
public struct Backup: Sendable, Codable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "backup"

  public var id: Int64?
  public var kind: String
  public var name: String
  public var payload: Data
  public var createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id, kind, name, payload
    case createdAt = "created_at"
  }

  public init(id: Int64?, kind: String, name: String, payload: Data, createdAt: Date) {
    self.id = id
    self.kind = kind
    self.name = name
    self.payload = payload
    self.createdAt = createdAt
  }
}

public struct BackupRepository: Sendable {

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func all(kind: String) async throws -> [Backup] {
    try await database.read { db in
      try Backup.filter(Column("kind") == kind).order(Column("name")).fetchAll(db)
    }
  }

  /// Stores a backup, replacing any of the same kind and name.
  public func save(kind: String, name: String, payload: Data) async throws {
    try await database.write { db in
      // `let`: Backup is a PersistableRecord, so `save` is non-mutating and there is no
      // generated id written back into the value.
      let record = Backup(
        id: try Backup
          .filter(Column("kind") == kind && Column("name") == name)
          .fetchOne(db)?.id,
        kind: kind,
        name: name,
        payload: payload,
        createdAt: Date()
      )
      try record.save(db)
    }
  }

  /// Deletes one backup by name, or every backup of a kind when `name` is nil.
  ///
  /// - Returns: how many rows were removed.
  @discardableResult
  public func delete(kind: String, name: String?) async throws -> Int {
    try await database.write { db in
      var request = Backup.filter(Column("kind") == kind)
      if let name { request = request.filter(Column("name") == name) }
      return try request.deleteAll(db)
    }
  }
}
