//  CallHistoryRepository
//  Read-only access to the macOS call log, for the FaceTime recents API.
//
//  WHY A DATABASE AND NOT THE PRIVATE API. `TUCallCenter` exposes the calls happening NOW and
//  keeps no history — there is no "recent calls" selector on it (checked against the dumped
//  headers). The log lives in a Core Data store that FaceTime and Phone both write:
//
//      ~/Library/Application Support/CallHistoryDB/CallHistory.storedata
//
//  Reading it directly means recents work with NO helper injected and no SIP changes — this
//  is the one FaceTime feature that needs neither. It needs Full Disk Access, which the
//  server already has for chat.db.
//
//  The same two rules as chat.db apply, for the same reason: never SELECT *, and never assume
//  a column exists. Apple owns this schema.
//
//  THE JOIN TABLE NAME IS NOT A CONSTANT. Core Data names its many-to-many tables after
//  internal ENTITY NUMBERS — this machine has `Z_2REMOTEPARTICIPANTHANDLES` with columns
//  `Z_2REMOTEPARTICIPANTCALLS` / `Z_4REMOTEPARTICIPANTHANDLES`. Those digits are assigned by
//  the model compiler and shift when Apple adds an entity, so hardcoding them would silently
//  return zero participants on some other macOS build. They are discovered at runtime instead.

import BBPersistence
import BBPrivateAPIContract
import Foundation
import GRDB
import Logging

// MARK: - Model

/// One entry in the call log, narrowed to what a client would show in a recents list.
///
/// `ZCALLRECORD` carries junk-confidence scores, carrier identifiers, emergency-call and
/// screen-sharing flags, blocking-extension names and a trust score. None of that belongs in
/// a recents list, and some of it is a privacy hazard to hand out, so it is not exposed.
public struct CallRecord: Sendable, Equatable, Codable {
  /// FaceTime's own identifier for the call, stable across reads.
  public let id: String
  /// The other party, as dialled or received. Nil on a record Apple stored without one.
  public let address: String?
  /// The name macOS resolved at the time of the call.
  public let displayName: String?
  public let date: Date
  public let duration: TimeInterval
  public let isOutgoing: Bool
  public let isAnswered: Bool
  /// Video vs audio. FaceTime video is call type 8; audio is 16.
  public let isVideo: Bool
  /// `com.apple.FaceTime` for FaceTime; carrier calls report their own provider.
  public let service: String?
  /// Set when the call was a group conversation.
  public let groupUUID: String?
  /// Everyone on the far side. A 1:1 call has one; a group call has several.
  public let participants: [String]

  /// Incoming and never answered — what a client badges as missed. Derived rather than
  /// stored, because the database has no "missed" column: it records direction and answer
  /// separately, and an unanswered OUTGOING call is not a missed call.
  public var isMissed: Bool { !isOutgoing && !isAnswered }

  public init(
    id: String, address: String?, displayName: String?, date: Date,
    duration: TimeInterval, isOutgoing: Bool, isAnswered: Bool, isVideo: Bool,
    service: String?, groupUUID: String?, participants: [String]
  ) {
    self.id = id
    self.address = address
    self.displayName = displayName
    self.date = date
    self.duration = duration
    self.isOutgoing = isOutgoing
    self.isAnswered = isAnswered
    self.isVideo = isVideo
    self.service = service
    self.groupUUID = groupUUID
    self.participants = participants
  }
}

// MARK: - Repository

public struct CallHistoryRepository: Sendable {

  /// Core Data counts seconds from 2001-01-01, not from the Unix epoch.
  static let coreDataEpochOffset: TimeInterval = 978_307_200

  /// The service provider FaceTime writes. Phone calls carry a carrier identifier instead.
  public static let faceTimeService = "com.apple.FaceTime"

  private let database: ReadOnlyDatabase
  private let schema: Schema
  private let logger = Logger(label: "bluebubbles.callhistory")

  public static var defaultPath: String {
    SocketLocation.realHomeDirectory
      + "/Library/Application Support/CallHistoryDB/CallHistory.storedata"
  }

  /// Opens the log, or returns nil when this Mac has none.
  ///
  /// A missing store is NOT an error: a machine that has never placed a FaceTime or phone
  /// call has no `CallHistoryDB` at all, and the honest answer for that is an empty list
  /// rather than a 500 telling the user something is broken.
  public init?(path: String = CallHistoryRepository.defaultPath) async throws {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let database = try ReadOnlyDatabase(path: path)
    guard let schema = try await Schema(database: database) else { return nil }
    self.database = database
    self.schema = schema
  }

  // MARK: - Schema discovery

  /// What THIS machine's store actually contains.
  struct Schema: Sendable {
    let callColumns: Set<String>
    /// Nil when the many-to-many table is absent or unrecognised — participants are then
    /// reported as just the record's own address rather than failing the whole query.
    let participantJoin: ParticipantJoin?

    struct ParticipantJoin: Sendable {
      let table: String
      let callColumn: String
      let handleColumn: String
    }

    init?(database: ReadOnlyDatabase) async throws {
      let tables = try await database.tables()
      guard tables.contains("ZCALLRECORD") else { return nil }
      self.callColumns = try await database.columns(of: "ZCALLRECORD")

      // Core Data numbers this table by entity id, so match on shape, not on a literal.
      guard tables.contains("ZHANDLE"),
        let table = tables.first(where: {
          $0.hasPrefix("Z_") && $0.hasSuffix("REMOTEPARTICIPANTHANDLES")
        })
      else {
        self.participantJoin = nil
        return
      }
      let columns = try await database.columns(of: table)
      guard let callColumn = columns.first(where: { $0.hasSuffix("CALLS") }),
        let handleColumn = columns.first(where: { $0.hasSuffix("HANDLES") })
      else {
        self.participantJoin = nil
        return
      }
      self.participantJoin = ParticipantJoin(
        table: table, callColumn: callColumn, handleColumn: handleColumn
      )
    }
  }

  /// Requested columns filtered to the ones that exist, so a schema change drops a FIELD
  /// rather than taking the whole query down.
  private func selectable(_ requested: [String]) -> [String] {
    requested.filter { schema.callColumns.contains($0) }
  }

  // MARK: - Reads

  /// The most recent calls, newest first.
  ///
  /// Ordered by `ZDATE DESC`, which is the one index Apple ships on this table
  /// (`Z_CallRecord_byDateIndex`) — so the page is an index scan rather than a sort of the
  /// entire log.
  public func recents(
    limit: Int = 50,
    offset: Int = 0,
    faceTimeOnly: Bool = true
  ) async throws -> [CallRecord] {
    let columns = selectable([
      "Z_PK", "ZUNIQUE_ID", "ZADDRESS", "ZNAME", "ZDATE", "ZDURATION",
      "ZORIGINATED", "ZANSWERED", "ZCALLTYPE", "ZSERVICE_PROVIDER",
      "ZPARTICIPANTGROUPUUID",
    ])
    guard columns.contains("ZDATE") else { return [] }

    // `Row` is not Sendable, so every row is mapped to a value type INSIDE the read
    // block; only Sendable data crosses back out.
    let filterService =
      (faceTimeOnly && schema.callColumns.contains("ZSERVICE_PROVIDER"))
      ? Self.faceTimeService : nil
    let sql =
      "SELECT \(columns.joined(separator: ", ")) FROM ZCALLRECORD"
      + (filterService != nil ? " WHERE ZSERVICE_PROVIDER = ?" : "")
      + " ORDER BY ZDATE DESC LIMIT ? OFFSET ?"
    let page = max(0, limit)
    let skip = max(0, offset)

    let raw: [RawRecord] = try await database.read { db in
      var arguments: [any DatabaseValueConvertible] = []
      if let filterService { arguments.append(filterService) }
      arguments.append(page)
      arguments.append(skip)
      return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        .compactMap(RawRecord.init(row:))
    }

    // Participants in ONE query for the whole page. Per-record lookups would make a
    // 50-call page 51 queries against a database another process is writing.
    let participants = try await participantsByCall(callKeys: raw.compactMap(\.key))
    return raw.map { $0.record(participants: participants) }
  }

  /// A row, decoded into something that can leave the database's isolation.
  private struct RawRecord: Sendable {
    let key: Int64?
    let uniqueID: String?
    let address: String?
    let displayName: String?
    let date: Double
    let duration: Double
    let originated: Bool
    let answered: Bool
    let callType: Int?
    let service: String?
    let groupUUID: String?

    init?(row: Row) {
      guard let date = row["ZDATE"] as Double? else { return nil }
      self.date = date
      self.key = row["Z_PK"] as Int64?
      self.uniqueID = (row["ZUNIQUE_ID"] as String?).flatMap { $0.isEmpty ? nil : $0 }
      self.address = (row["ZADDRESS"] as String?).flatMap { $0.isEmpty ? nil : $0 }
      self.displayName = (row["ZNAME"] as String?).flatMap { $0.isEmpty ? nil : $0 }
      self.duration = (row["ZDURATION"] as Double?) ?? 0
      self.originated = (row["ZORIGINATED"] as Int?) == 1
      self.answered = (row["ZANSWERED"] as Int?) == 1
      self.callType = row["ZCALLTYPE"] as Int?
      self.service = row["ZSERVICE_PROVIDER"] as String?
      self.groupUUID = (row["ZPARTICIPANTGROUPUUID"] as Data?)
        .flatMap(CallHistoryRepository.uuidString(from:))
    }

    func record(participants: [Int64: [String]]) -> CallRecord {
      let joined = key.flatMap { participants[$0] } ?? []
      return CallRecord(
        // Fall back to the row key so every record has a stable id even if Apple ever
        // stops populating ZUNIQUE_ID — a client de-duplicating on id must never see
        // two distinct calls collapse into one.
        id: uniqueID ?? "callrecord-\(key.map(String.init) ?? UUID().uuidString)",
        address: address,
        displayName: displayName,
        date: Date(
          timeIntervalSince1970: date + CallHistoryRepository.coreDataEpochOffset
        ),
        duration: duration,
        isOutgoing: originated,
        isAnswered: answered,
        isVideo: callType == 8,
        service: service,
        groupUUID: groupUUID,
        // A 1:1 call has no join rows on some builds, so fall back to the address
        // rather than reporting a call with nobody on it.
        participants: joined.isEmpty ? [address].compactMap { $0 } : joined
      )
    }
  }

  private func participantsByCall(callKeys: [Int64]) async throws -> [Int64: [String]] {
    guard let join = schema.participantJoin, !callKeys.isEmpty else { return [:] }
    let placeholders = Array(repeating: "?", count: callKeys.count).joined(separator: ", ")
    let sql = """
      SELECT j.\(join.callColumn) AS call_key, h.ZVALUE AS value
      FROM \(join.table) j
      JOIN ZHANDLE h ON h.Z_PK = j.\(join.handleColumn)
      WHERE j.\(join.callColumn) IN (\(placeholders))
      """
    return try await database.read { db in
      var result: [Int64: [String]] = [:]
      let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(callKeys))
      for row in rows {
        guard let key = row["call_key"] as Int64?,
          let value = row["value"] as String?, !value.isEmpty
        else { continue }
        result[key, default: []].append(value)
      }
      return result
    }
  }

  /// Core Data stores a UUID as a raw 16-byte blob, not as text.
  static func uuidString(from data: Data) -> String? {
    guard data.count == 16 else { return nil }
    return UUID(uuid: data.withUnsafeBytes { $0.load(as: uuid_t.self) }).uuidString
  }
}
