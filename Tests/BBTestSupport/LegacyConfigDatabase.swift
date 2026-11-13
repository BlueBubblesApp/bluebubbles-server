//  LegacyConfigDatabase
//  An Electron install's settings database, as far as the import reads it.
//
//  The Electron server kept its settings in a `config` table of `(name TEXT, value TEXT)`,
//  everything a string. The importer's unit tests and the wiring test that proves the import
//  is called both need one, and wrote the same table by hand.

import Foundation
import GRDB

public enum LegacyConfigDatabase {

  /// A database at a fresh temporary path holding `values` in a `config` table.
  ///
  /// The caller removes it.
  public static func make(_ values: [String: String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-legacy-\(UUID().uuidString).db")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE config (name TEXT PRIMARY KEY, value TEXT)")
      for (name, value) in values {
        try db.execute(
          sql: "INSERT INTO config (name, value) VALUES (?, ?)",
          arguments: [name, value]
        )
      }
    }
    return url
  }
}
