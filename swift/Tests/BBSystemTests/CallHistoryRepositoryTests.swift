//  CallHistoryRepositoryTests
//  The FaceTime recents read, against a synthetic CallHistoryDB.
//
//  The real store belongs to macOS and holds the tester's actual call log, so these build
//  their own — which also lets them assert the things a real store cannot: a DIFFERENT Core
//  Data entity numbering, and a schema missing columns.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBSystem
import Foundation
import GRDB
import Testing

@Suite("Call history")
struct CallHistoryRepositoryTests {

  /// Builds a store shaped like Apple's. `entityNumbers` picks the Core Data join-table
  /// numbering, which is exactly what must NOT be hardcoded.
  private static func makeStore(
    at path: String,
    callEntity: Int = 2,
    handleEntity: Int = 4,
    includeServiceColumn: Bool = true
  ) throws {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
      try db.execute(
        sql: """
          CREATE TABLE ZCALLRECORD (
              Z_PK INTEGER PRIMARY KEY, ZANSWERED INTEGER, ZCALLTYPE INTEGER,
              ZORIGINATED INTEGER, ZDATE TIMESTAMP, ZDURATION FLOAT,
              ZADDRESS VARCHAR, ZNAME VARCHAR, ZUNIQUE_ID VARCHAR
              \(includeServiceColumn ? ", ZSERVICE_PROVIDER VARCHAR" : "")
              , ZPARTICIPANTGROUPUUID BLOB
          )
          """)
      try db.execute(
        sql: """
          CREATE TABLE ZHANDLE (
              Z_PK INTEGER PRIMARY KEY, ZTYPE INTEGER,
              ZNORMALIZEDVALUE VARCHAR, ZVALUE VARCHAR
          )
          """)
      try db.execute(
        sql: """
          CREATE TABLE Z_\(callEntity)REMOTEPARTICIPANTHANDLES (
              Z_\(callEntity)REMOTEPARTICIPANTCALLS INTEGER,
              Z_\(handleEntity)REMOTEPARTICIPANTHANDLES INTEGER,
              PRIMARY KEY (Z_\(callEntity)REMOTEPARTICIPANTCALLS,
                           Z_\(handleEntity)REMOTEPARTICIPANTHANDLES)
          )
          """)

      // 2026-08-30 01:06:05Z and one minute earlier, in Core Data's 2001 epoch.
      let newer = 1_756_515_965.0 - 978_307_200.0
      let older = newer - 60
      let service = includeServiceColumn ? ", ZSERVICE_PROVIDER" : ""
      let facetime = includeServiceColumn ? ", 'com.apple.FaceTime'" : ""
      let phone = includeServiceColumn ? ", 'com.apple.Telephony'" : ""

      try db.execute(
        sql: """
          INSERT INTO ZCALLRECORD
              (Z_PK, ZANSWERED, ZCALLTYPE, ZORIGINATED, ZDATE, ZDURATION,
               ZADDRESS, ZNAME, ZUNIQUE_ID\(service))
          VALUES (1, 0, 8, 1, \(newer), 16.0,
                  'person@example.com', 'Example Person', 'UID-NEWER'\(facetime))
          """)
      try db.execute(
        sql: """
          INSERT INTO ZCALLRECORD
              (Z_PK, ZANSWERED, ZCALLTYPE, ZORIGINATED, ZDATE, ZDURATION,
               ZADDRESS, ZNAME, ZUNIQUE_ID\(service))
          VALUES (2, 0, 16, 0, \(older), 0.0,
                  '+15550000001', NULL, 'UID-OLDER'\(facetime))
          """)
      // A carrier call, to prove the default filter excludes it.
      try db.execute(
        sql: """
          INSERT INTO ZCALLRECORD
              (Z_PK, ZANSWERED, ZCALLTYPE, ZORIGINATED, ZDATE, ZDURATION,
               ZADDRESS, ZNAME, ZUNIQUE_ID\(service))
          VALUES (3, 1, 1, 0, \(older - 60), 12.0,
                  '+15550000002', NULL, 'UID-PHONE'\(phone))
          """)

      try db.execute(
        sql: """
          INSERT INTO ZHANDLE (Z_PK, ZTYPE, ZVALUE)
          VALUES (10, 3, 'person@example.com'), (11, 2, '+15550000003')
          """)
      // The newer call was a group: two people on the far side.
      try db.execute(
        sql: """
          INSERT INTO Z_\(callEntity)REMOTEPARTICIPANTHANDLES VALUES (1, 10), (1, 11)
          """)
    }
  }

  private static func temporaryPath(_ name: String) -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-callhistory-\(name)-\(UUID().uuidString).sqlite").path
  }

  @Test("Recents come back newest first, with direction, media and duration")
  func readsRecents() async throws {
    let path = Self.temporaryPath("recents")
    try Self.makeStore(at: path)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let repository = try #require(try await CallHistoryRepository(path: path))
    let calls = try await repository.recents()

    // The carrier call is excluded by default.
    #expect(calls.count == 2)
    let newest = try #require(calls.first)
    #expect(newest.id == "UID-NEWER")
    #expect(newest.displayName == "Example Person")
    #expect(newest.isOutgoing)
    #expect(newest.isVideo)  // call type 8
    #expect(newest.duration == 16)
    // Outgoing and unanswered is NOT a missed call.
    #expect(newest.isMissed == false)

    let older = try #require(calls.last)
    #expect(older.isVideo == false)  // call type 16 is audio
    #expect(older.isOutgoing == false)
    #expect(older.isMissed)  // incoming and unanswered
  }

  /// The Core Data epoch is 2001-01-01, not 1970 — reading it as Unix time puts every call
  /// 31 years in the past.
  @Test("Dates convert from the Core Data epoch")
  func convertsDates() async throws {
    let path = Self.temporaryPath("dates")
    try Self.makeStore(at: path)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let repository = try #require(try await CallHistoryRepository(path: path))
    let newest = try #require(try await repository.recents().first)
    #expect(abs(newest.date.timeIntervalSince1970 - 1_756_515_965.0) < 1)
  }

  /// Core Data names its join tables after internal entity numbers, which shift when Apple
  /// adds an entity. Hardcoding `Z_2REMOTEPARTICIPANTHANDLES` would return zero
  /// participants on a build that numbers them differently — silently.
  @Test("Participants resolve under any Core Data entity numbering")
  func discoversJoinTable() async throws {
    for (callEntity, handleEntity) in [(2, 4), (7, 9)] {
      let path = Self.temporaryPath("join-\(callEntity)")
      try Self.makeStore(at: path, callEntity: callEntity, handleEntity: handleEntity)
      defer { try? FileManager.default.removeItem(atPath: path) }

      let repository = try #require(try await CallHistoryRepository(path: path))
      let newest = try #require(try await repository.recents().first)
      #expect(newest.participants.sorted() == ["+15550000003", "person@example.com"])
    }
  }

  /// A 1:1 call has no join rows, and reporting it with an empty participant list would
  /// make it look like a call with nobody on it.
  @Test("A call with no join rows falls back to its own address")
  func fallsBackToAddress() async throws {
    let path = Self.temporaryPath("solo")
    try Self.makeStore(at: path)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let repository = try #require(try await CallHistoryRepository(path: path))
    let older = try #require(try await repository.recents().last)
    #expect(older.participants == ["+15550000001"])
  }

  @Test("service=all includes carrier calls")
  func includesPhoneCalls() async throws {
    let path = Self.temporaryPath("all")
    try Self.makeStore(at: path)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let repository = try #require(try await CallHistoryRepository(path: path))
    let calls = try await repository.recents(faceTimeOnly: false)
    #expect(calls.count == 3)
    #expect(calls.contains { $0.service == "com.apple.Telephony" })
  }

  @Test("Paging is stable across limit and offset")
  func pages() async throws {
    let path = Self.temporaryPath("paging")
    try Self.makeStore(at: path)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let repository = try #require(try await CallHistoryRepository(path: path))
    let first = try await repository.recents(limit: 1, offset: 0)
    let second = try await repository.recents(limit: 1, offset: 1)
    #expect(first.first?.id == "UID-NEWER")
    #expect(second.first?.id == "UID-OLDER")
  }

  /// Apple owns this schema and removes columns between releases. A missing column must
  /// cost the FIELD, not the whole query.
  @Test("A missing column drops the field, not the query")
  func toleratesMissingColumns() async throws {
    let path = Self.temporaryPath("noservice")
    try Self.makeStore(at: path, includeServiceColumn: false)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let repository = try #require(try await CallHistoryRepository(path: path))
    // Without ZSERVICE_PROVIDER there is nothing to filter on, so everything comes back
    // rather than nothing.
    let calls = try await repository.recents()
    #expect(calls.count == 3)
    #expect(calls.allSatisfy { $0.service == nil })
  }

  /// A Mac that has never placed a call has no store at all. That is a real state, and the
  /// answer is an empty list — not a 500.
  @Test("A missing store is nil, not an error")
  func missingStore() async throws {
    let path = Self.temporaryPath("absent")
    #expect(try await CallHistoryRepository(path: path) == nil)
  }
}
