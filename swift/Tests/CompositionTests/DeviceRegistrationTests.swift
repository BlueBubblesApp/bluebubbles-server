//  DeviceRegistrationTests
//  The push registration write path, which nothing had ever executed.
//
//  `DeviceRepository.register` is the statement behind `POST /api/v1/fcm/device` — the call
//  every client makes on launch and after every FCM token rotation. It inserted into
//  `device.last_active`, and no such column exists: `createDevices` creates that name and
//  `normaliseTimestampColumnNames`, which runs after every contributor, renames it to
//  `last_active_at`. The record's `CodingKeys` had followed the rename; the hand-written SQL
//  next to them had not. Every registration failed at prepare time.
//
//  It survived a full test suite because every test that touched this table went through
//  `tokens()`, `prune()` or `deleteAll()` — the three statements that do not name the column.
//  So the tests below exercise the WRITE, and pin the schema the write assumes.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md. Registration tokens here are obvious fakes.

import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Device registration")
struct DeviceRegistrationTests {

  private func database() throws -> AppDatabase {
    try AppDatabase.inMemory(contributors: AppSchema.contributors)
  }

  /// The regression, in the plainest form it has: the statement runs at all.
  @Test("Registering a device stores it")
  func registerStoresTheDevice() async throws {
    let database = try database()
    let devices = DeviceRepository(database: database)

    try await devices.register(name: "Test Phone", identifier: "fcm-token-aaa")

    #expect(try await devices.tokens() == ["fcm-token-aaa"])
  }

  /// A client re-registers on every launch, so the common path is a conflict, not an insert.
  /// A plain insert would fail the unique constraint and read to the user as the server
  /// rejecting their phone.
  @Test("Re-registering the same token updates the row rather than adding one")
  func reRegistrationUpserts() async throws {
    let database = try database()
    let devices = DeviceRepository(database: database)
    let first = Date(timeIntervalSince1970: 1_700_000_000)
    let second = first.addingTimeInterval(3600)

    try await devices.register(name: "Old Name", identifier: "fcm-token-bbb", at: first)
    try await devices.register(name: "New Name", identifier: "fcm-token-bbb", at: second)

    let rows = try await database.read { db in try Device.fetchAll(db) }
    #expect(rows.count == 1)
    #expect(rows.first?.name == "New Name")
    #expect(rows.first?.lastActive == second)
  }

  /// `supported_codecs` and `public_key` are negotiated on a different path from the one
  /// that registers a token. A registration that does not carry them must not blank them —
  /// which is the whole reason this is a targeted `DO UPDATE SET` and not a record upsert.
  @Test("A re-registration leaves negotiated capabilities alone")
  func negotiatedColumnsSurvive() async throws {
    let database = try database()
    let devices = DeviceRepository(database: database)
    let key = Data([0x01, 0x02, 0x03])

    try await database.write { db in
      try Device(
        name: "Test Phone",
        identifier: "fcm-token-ccc",
        lastActive: Date(timeIntervalSince1970: 1_700_000_000),
        supportedCodecs: "sealed-v2,legacy-v1",
        publicKey: key
      ).insert(db)
    }

    try await devices.register(name: "Test Phone Renamed", identifier: "fcm-token-ccc")

    let row = try await database.read { db in try Device.fetchOne(db) }
    #expect(row?.name == "Test Phone Renamed")
    #expect(row?.supportedCodecs == "sealed-v2,legacy-v1")
    #expect(row?.publicKey == key)
  }

  /// The check that would have caught the drift on its own. `register` names its column in a
  /// string, so nothing in the compiler connects it to the migration that renamed it — but
  /// the migrated schema is knowable, and this asserts what it actually is.
  @Test("The migrated device table carries last_active_at, not last_active")
  func migratedColumnName() async throws {
    let database = try database()

    let columns = try await database.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(device)")
        .compactMap { $0["name"] as String? }
    }

    #expect(columns.contains("last_active_at"))
    #expect(!columns.contains("last_active"))
  }
}
