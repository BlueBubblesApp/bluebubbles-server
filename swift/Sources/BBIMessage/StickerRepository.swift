//  StickerRepository
//  Read-only access to this Mac's sticker store.
//
//  The store is `stickers.stickerdb` in the `com.apple.stickersd.group` container — a Core
//  Data + CloudKit database owned by `stickersd`, holding two tables worth reading:
//
//    ZMANAGEDSTICKER          one row per sticker, with its identity, origin and dates
//    ZMANAGEDREPRESENTATION   one row per rendition, INCLUDING the image bytes in ZDATA
//
//  So the bytes are right there, and reading needs no Private API at all: listing and
//  downloading stickers works on a Mac with no helper, which is why this is a repository
//  next to `MessageRepository` rather than another helper call. WRITING does need the
//  helper — the container is entitled to the app group and this server is not. See
//  `IMStickerStore` in the helper, and `docs/STICKER_LIBRARY.md`.
//
//  The same two rules as chat.db hold, for the same reasons: never SELECT *, and never
//  widen a query to avoid a join. Apple owns this schema too, and `stickers.stickerdb` is
//  newer than chat.db — it did not exist before Sonoma — so a column here is if anything
//  more likely to move.

import BBCore
import BBPersistence
import Foundation
import GRDB

/// Which shelf of the store a sticker sits on.
///
/// `ZMANAGEDSTICKER.ZTYPE`, and the mapping was read off the store rather than guessed. The
/// giveaway is a sticker that is on BOTH shelves: this Mac holds one custom Live Sticker,
/// and the store has two rows for it — a `ZTYPE = 1` row whose own identifier is
/// `AC20781C-…`, and a `ZTYPE = 0` row with a fresh identifier whose `ZEXTERNALURI` is
/// `sticker:///user/identifier/AC20781C-…`, pointing back at the first.
///
/// A donation to recents is exactly that shape — `donateStickerToRecents…` takes a NEW
/// identifier and an external URI naming the source — so `0` is the recent and `1` is the
/// saved original. It holds for the rest of the store too: the emoji and Memoji rows are all
/// `ZTYPE = 0` with `sticker:///emoji/…` and `sticker:///memoji/…` URIs, which is right,
/// because an emoji sticker is generated on use and only ever exists as a recent.
///
/// CONFIRMED by donating one: `POST /api/v2/sticker` produced a `ZTYPE = 0` row, with the
/// `ZLIBRARYINDEX` above every existing one. So the inference above is not just consistent
/// with the store, it is what the store does.
public enum StickerShelf: String, Sendable, CaseIterable {
  /// Recently used. Emoji and Memoji stickers only ever appear here.
  case recent
  /// The sticker drawer: what the user made and kept. Syncs through iCloud.
  case saved

  var storedType: Int {
    switch self {
    case .recent: 0
    case .saved: 1
    }
  }

  static func shelf(forStoredType type: Int) -> StickerShelf? {
    StickerShelf.allCases.first { $0.storedType == type }
  }
}

/// One rendition of a sticker. A sticker has at least one and often two.
///
/// Messages writes two for a sticker it made itself — a full-size `still` HEIC and a small
/// `keyboard` PNG for the picker — and one with an EMPTY role for the emoji and Memoji rows.
/// A client picking a rendition should ask for a role and fall back to the preferred one,
/// which is what `bytes(identifier:role:)` does.
public struct StickerRepresentationRow: Sendable, Equatable {
  public let identifier: String
  public let role: String
  public let uti: String
  public let width: Double
  public let height: Double
  public let byteCount: Int
  public let isPreferred: Bool

  public init(
    identifier: String, role: String, uti: String, width: Double, height: Double,
    byteCount: Int, isPreferred: Bool
  ) {
    self.identifier = identifier
    self.role = role
    self.uti = uti
    self.width = width
    self.height = height
    self.byteCount = byteCount
    self.isPreferred = isPreferred
  }

  /// The role Messages uses for a full-size rendition.
  public static let stillRole = "com.apple.stickers.role.still"
  /// The role Messages uses for the picker thumbnail.
  public static let keyboardRole = "com.apple.stickers.role.keyboard"
}

public struct StickerRow: Sendable, Equatable {
  public let identifier: String
  public let shelf: StickerShelf
  /// `sticker:///emoji/identifier/📀`, `sticker:///memoji/cow/…`,
  /// `sticker:///user/identifier/<UUID>`. The most useful single field for a client: it is
  /// what says whether this is an emoji, a Memoji or something the user made.
  public let externalURI: String
  public let name: String?
  /// What VoiceOver reads. Messages fills it in from its own subject recognition, so it
  /// reads like `loudly crying face` — and it is what the picker's search matches on.
  public let accessibilityName: String?
  public let searchText: String?
  public let byteCount: Int
  /// -1 on a plain sticker; 0 or more when an effect is applied.
  public let effect: Int
  public let createdAt: Date?
  public let lastUsedAt: Date?
  /// The store's own ordering value within a shelf. Larger is more recent.
  public let libraryIndex: Double?
  public let attributionName: String?
  public let attributionBundleID: String?
  public let representations: [StickerRepresentationRow]

  public init(
    identifier: String, shelf: StickerShelf, externalURI: String, name: String?,
    accessibilityName: String?, searchText: String?, byteCount: Int, effect: Int,
    createdAt: Date?, lastUsedAt: Date?, libraryIndex: Double?, attributionName: String?,
    attributionBundleID: String?, representations: [StickerRepresentationRow]
  ) {
    self.identifier = identifier
    self.shelf = shelf
    self.externalURI = externalURI
    self.name = name
    self.accessibilityName = accessibilityName
    self.searchText = searchText
    self.byteCount = byteCount
    self.effect = effect
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.libraryIndex = libraryIndex
    self.attributionName = attributionName
    self.attributionBundleID = attributionBundleID
    self.representations = representations
  }
}

public struct StickerRepository: Sendable {

  private let database: ReadOnlyDatabase

  public init(database: ReadOnlyDatabase) {
    self.database = database
  }

  /// Where `stickersd` keeps the store, under the user's home.
  ///
  /// A group container, so reading it needs Full Disk Access — the same grant chat.db needs,
  /// which this server already requires and checks for. It is absent on a Mac that has never
  /// had a sticker, which is a store with nothing in it rather than an error.
  public static func defaultPath(home: URL = URL(fileURLWithPath: NSHomeDirectory()))
    -> String
  {
    home
      .appendingPathComponent("Library/Group Containers/com.apple.stickersd.group")
      .appendingPathComponent("Stickers/stickers.stickerdb")
      .path
  }

  // MARK: - Columns
  //
  // Named rather than starred, and the identifier columns are BLOBs holding raw 16-byte
  // UUIDs — hence `hex()` in SQL and `Self.uuid(...)` on the way out.

  private static let stickerColumns = """
    s.Z_PK AS pk, s.ZTYPE AS type, hex(s.ZIDENTIFIER) AS identifier,
    s.ZEXTERNALURI AS externalURI, s.ZNAME AS name,
    s.ZACCESSIBILITYNAME AS accessibilityName, s.ZSEARCHTEXT AS searchText,
    s.ZBYTECOUNT AS byteCount, s.ZEFFECT AS effect,
    s.ZCREATIONDATE AS createdAt, s.ZLASTUSEDDATE AS lastUsedAt,
    s.ZLIBRARYINDEX AS libraryIndex, s.ZATTRIBUTIONNAME AS attributionName,
    s.ZATTRIBUTIONBUNDLEIDENTIFIER AS attributionBundleID
    """

  private static let representationColumns = """
    r.ZSTICKER AS sticker, hex(r.ZIDENTIFIER) AS identifier, r.ZROLE AS role,
    r.ZUTI AS uti, r.ZSIZE_W AS width, r.ZSIZE_H AS height,
    r.ZBYTECOUNT AS byteCount, r.ZISPREFERRED AS isPreferred
    """

  /// Every sticker on the given shelves, newest first.
  ///
  /// Ordered by `ZLIBRARYINDEX` rather than by date because that is the store's own
  /// ordering — it is what the picker shows — and it does not always agree with
  /// `ZLASTUSEDDATE`. The date is reported too, so a client that wants recency can sort
  /// on it.
  ///
  /// Representations are fetched in ONE query for the whole page and joined in memory,
  /// rather than a query per sticker: a store with a few hundred stickers would otherwise
  /// be a few hundred round trips for a list nobody paged.
  public func stickers(
    shelves: Set<StickerShelf> = Set(StickerShelf.allCases),
    limit: Int = 100,
    offset: Int = 0
  ) async throws -> [StickerRow] {
    guard !shelves.isEmpty else { return [] }
    let types = shelves.map(\.storedType).sorted()
    let placeholders = types.map { _ in "?" }.joined(separator: ", ")
    let arguments = types + [limit, offset]

    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT \(Self.stickerColumns) FROM ZMANAGEDSTICKER s
          WHERE s.ZTYPE IN (\(placeholders))
          ORDER BY s.ZLIBRARYINDEX DESC, s.Z_PK DESC
          LIMIT ? OFFSET ?
          """,
        arguments: StatementArguments(arguments)
      )
      let keys = rows.compactMap { $0["pk"] as Int? }
      return Self.assemble(rows, representations: try Self.representations(db, stickerKeys: keys))
    }
  }

  /// How many stickers each shelf holds, so a client can page without walking the store.
  public func counts() async throws -> [StickerShelf: Int] {
    try await database.read { db in
      var counts: [StickerShelf: Int] = [:]
      let rows = try Row.fetchAll(
        db, sql: "SELECT ZTYPE AS type, COUNT(*) AS total FROM ZMANAGEDSTICKER GROUP BY ZTYPE")
      for row in rows {
        guard let type = row["type"] as Int?, let shelf = StickerShelf.shelf(forStoredType: type)
        else { continue }
        counts[shelf] = row["total"] as Int? ?? 0
      }
      return counts
    }
  }

  /// One sticker by identifier, with its representations.
  ///
  /// The identifier is matched against the hex of the UUID blob, so a client may send the
  /// canonical dashed form or bare hex; both normalise to the same 32 characters.
  public func sticker(identifier: String) async throws -> StickerRow? {
    guard let hex = Self.hex(identifier) else { return nil }
    return try await database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT \(Self.stickerColumns) FROM ZMANAGEDSTICKER s
            WHERE hex(s.ZIDENTIFIER) = ? LIMIT 1
            """,
          arguments: [hex]
        ), let key = row["pk"] as Int?
      else { return nil }
      return Self.assemble(
        [row], representations: try Self.representations(db, stickerKeys: [key])
      ).first
    }
  }

  /// One sticker by its `ZEXTERNALURI`, which is how a DONATION is found again.
  ///
  /// `donateStickerToRecents…` takes an identifier and does NOT file the row under it: the
  /// store mints its own row identifier and records the one it was given as the external
  /// URI, exactly as it does for the saved sticker a recent points back at. Measured — the
  /// first version of the save route answered with the donation's identifier, and every
  /// read of it 404'd.
  ///
  /// Newest first, because an image donated twice is two rows with the same URI and the
  /// caller means the one it just made.
  public func sticker(externalURI: String) async throws -> StickerRow? {
    try await database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT \(Self.stickerColumns) FROM ZMANAGEDSTICKER s
            WHERE s.ZEXTERNALURI = ? ORDER BY s.Z_PK DESC LIMIT 1
            """,
          arguments: [externalURI]
        ), let key = row["pk"] as Int?
      else { return nil }
      return Self.assemble(
        [row], representations: try Self.representations(db, stickerKeys: [key])
      ).first
    }
  }

  /// The image bytes of one rendition, and its UTI so a caller can name a content type.
  ///
  /// `role` picks the rendition. Nil takes the preferred one, which is the full-size
  /// rendition for a sticker Messages made and the only one for an emoji sticker. A role
  /// nothing matches falls back to preferred rather than 404ing, because "this sticker has
  /// no keyboard thumbnail" is not the same as "there is no such sticker" and a client
  /// asking for a thumbnail wants an image either way.
  public func bytes(identifier: String, role: String? = nil) async throws -> (
    data: Data, uti: String, role: String
  )? {
    guard let hex = Self.hex(identifier) else { return nil }
    return try await database.read { db in
      // ZDATA is read only here, never in a list query: these blobs are hundreds of
      // kilobytes each and a page of them would be tens of megabytes of nothing.
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT r.ZROLE AS role, r.ZUTI AS uti, r.ZISPREFERRED AS isPreferred,
                 r.ZDATA AS data
          FROM ZMANAGEDREPRESENTATION r
          JOIN ZMANAGEDSTICKER s ON s.Z_PK = r.ZSTICKER
          WHERE hex(s.ZIDENTIFIER) = ?
          ORDER BY r.ZINDEX ASC
          """,
        arguments: [hex]
      )
      guard !rows.isEmpty else { return nil }
      let chosen =
        role.flatMap { wanted in rows.first { ($0["role"] as String?) == wanted } }
        ?? rows.first { ($0["isPreferred"] as Int? ?? 0) != 0 }
        ?? rows[0]
      guard let data = chosen["data"] as Data?, !data.isEmpty else { return nil }
      return (
        data: data,
        uti: chosen["uti"] as String? ?? "public.png",
        role: chosen["role"] as String? ?? ""
      )
    }
  }

  // MARK: - Assembly

  private static func representations(_ db: Database, stickerKeys: [Int]) throws
    -> [Int: [StickerRepresentationRow]]
  {
    guard !stickerKeys.isEmpty else { return [:] }
    let placeholders = stickerKeys.map { _ in "?" }.joined(separator: ", ")
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT \(representationColumns) FROM ZMANAGEDREPRESENTATION r
        WHERE r.ZSTICKER IN (\(placeholders))
        ORDER BY r.ZSTICKER ASC, r.ZINDEX ASC
        """,
      arguments: StatementArguments(stickerKeys)
    )
    var byKey: [Int: [StickerRepresentationRow]] = [:]
    for row in rows {
      guard let key = row["sticker"] as Int? else { continue }
      byKey[key, default: []].append(
        StickerRepresentationRow(
          identifier: uuid(row["identifier"] as String?) ?? "",
          role: row["role"] as String? ?? "",
          uti: row["uti"] as String? ?? "",
          width: row["width"] as Double? ?? 0,
          height: row["height"] as Double? ?? 0,
          byteCount: row["byteCount"] as Int? ?? 0,
          isPreferred: (row["isPreferred"] as Int? ?? 0) != 0
        ))
    }
    return byKey
  }

  private static func assemble(
    _ rows: [Row], representations: [Int: [StickerRepresentationRow]]
  ) -> [StickerRow] {
    rows.compactMap { row in
      guard let key = row["pk"] as Int?,
        let identifier = uuid(row["identifier"] as String?),
        let shelf = StickerShelf.shelf(forStoredType: row["type"] as Int? ?? -1)
      else { return nil }
      return StickerRow(
        identifier: identifier,
        shelf: shelf,
        externalURI: row["externalURI"] as String? ?? "",
        name: nonEmpty(row["name"] as String?),
        accessibilityName: nonEmpty(row["accessibilityName"] as String?),
        searchText: nonEmpty(row["searchText"] as String?),
        byteCount: row["byteCount"] as Int? ?? 0,
        effect: row["effect"] as Int? ?? -1,
        createdAt: coreDataDate(row["createdAt"] as Double?),
        lastUsedAt: coreDataDate(row["lastUsedAt"] as Double?),
        libraryIndex: row["libraryIndex"] as Double?,
        attributionName: nonEmpty(row["attributionName"] as String?),
        attributionBundleID: nonEmpty(row["attributionBundleID"] as String?),
        representations: representations[key] ?? []
      )
    }
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  /// Core Data's own epoch, which is 2001-01-01 — the same one chat.db uses for seconds.
  private static func coreDataDate(_ value: Double?) -> Date? {
    guard let value, value > 0 else { return nil }
    return Date(timeIntervalSinceReferenceDate: value)
  }

  /// 32 hex characters, from either a dashed UUID or bare hex. Nil for anything else, which
  /// is how a malformed identifier becomes a 404 rather than a query.
  static func hex(_ identifier: String) -> String? {
    let stripped = identifier.replacingOccurrences(of: "-", with: "").uppercased()
    guard stripped.count == 32, stripped.allSatisfy(\.isHexDigit) else { return nil }
    return stripped
  }

  /// The dashed UUID for a 32-character hex string, so a client sees the same identifier
  /// shape everywhere rather than raw blob hex.
  static func uuid(_ hex: String?) -> String? {
    guard let hex, hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
    let characters = Array(hex.uppercased())
    let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
    return groups.map { String(characters[$0]) }.joined(separator: "-")
  }
}
