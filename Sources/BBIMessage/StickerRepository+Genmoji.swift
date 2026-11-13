//  StickerRepository+Genmoji
//  The Genmoji in this Mac's sticker store: the library a client shows the person.
//
//  A Genmoji has no table or entity of its own. It is a `ZMANAGEDSTICKER` row with a prompt
//  (`ZSANITIZEDPROMPT`), and that is the whole test: a custom Live Sticker carries a prompt
//  language and no prompt, and an emoji or Memoji sticker carries neither. The prompt
//  properties first appear on `STKSticker` in the Sequoia dump and are absent from Sonoma's,
//  so on Sonoma the column is missing and the library is empty rather than an error.
//
//  Three things measured on macOS 27.0.1, each of which shapes the code below:
//
//    - **One Genmoji is usually two rows.** Saving one writes a saved row (`ZTYPE = 1`, the
//      shelf iCloud syncs) and a recent (`ZTYPE = 0`) whose `ZEXTERNALURI` points back at it
//      as `sticker:///user/identifier/<UUID>`. The two share their renditions' identifiers
//      and bytes. So rows are grouped by that UUID, and the library lists each Genmoji once.
//    - **That UUID is the adaptive image glyph's content identifier.** A Genmoji sent from
//      Messages has the same value in chat.db's `attachment.emoji_image_content_identifier`,
//      and its `emoji_image_short_description` is the prompt. So the identifier this file
//      reports is the one a sent Genmoji carries, not a row key of the store's.
//    - **Each size is its own single-image HEIC**: `stillVariant_40` through `_320`, a
//      `keyboard` at 96 and a `still` at 1024, with no content identifier in their metadata. A
//      Genmoji Messages made can have the `still` alone. A caller picks a size from what is
//      there; `GenmojiLibraryInterface` does that and resizes.
//
//  Read-only, through the same column filtering as every other sticker query, and image bytes
//  are read one rendition at a time by its key, never in a listing.

import BBCore
import BBPersistence
import Foundation
import GRDB

/// One stored size of a Genmoji. No bytes: `StickerRepository.genmojiBytes(of:)` reads them.
public struct GenmojiRendition: Sendable, Equatable {
  /// The store's rendition identifier. A saved Genmoji and its recent copy share it, and their
  /// bytes are the same, so it names the pixels rather than the row.
  public let identifier: String
  public let role: String
  public let uti: String
  public let width: Int
  public let height: Int
  public let byteCount: Int
  /// `ZMANAGEDREPRESENTATION.Z_PK`, which the bytes are read back by.
  public let key: Int

  public init(
    identifier: String, role: String, uti: String, width: Int, height: Int, byteCount: Int,
    key: Int
  ) {
    self.identifier = identifier
    self.role = role
    self.uti = uti
    self.width = width
    self.height = height
    self.byteCount = byteCount
    self.key = key
  }
}

/// One Genmoji, however many rows of the store hold it.
public struct GenmojiRow: Sendable, Equatable {
  /// The adaptive image glyph's content identifier: what a sent Genmoji carries in chat.db.
  public let identifier: String
  /// The prompt as the store keeps it: Image Playground's own short form, which is also what
  /// VoiceOver reads and what the picker's search matches.
  public let description: String
  /// The prompt's language, such as `en_US`.
  public let languageIdentifier: String?
  public let createdAt: Date?
  public let lastUsedAt: Date?
  /// `saved` when it is in the drawer iCloud syncs, `recent` when it was used lately.
  public let shelves: Set<StickerShelf>
  /// The store's own row identifiers, saved first: what `GET sticker/:id` takes.
  public let stickerIdentifiers: [String]
  /// The sizes there are, smallest first.
  public let renditions: [GenmojiRendition]

  public init(
    identifier: String, description: String, languageIdentifier: String?, createdAt: Date?,
    lastUsedAt: Date?, shelves: Set<StickerShelf>, stickerIdentifiers: [String],
    renditions: [GenmojiRendition]
  ) {
    self.identifier = identifier
    self.description = description
    self.languageIdentifier = languageIdentifier
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.shelves = shelves
    self.stickerIdentifiers = stickerIdentifiers
    self.renditions = renditions
  }
}

extension StickerRepository {

  /// The external URI a recent copy names its saved Genmoji by, before the UUID.
  static let userURIPrefix = "sticker:///user/identifier/"

  /// Whether this macOS keeps Genmoji in the store at all: false on Sonoma, which has no
  /// prompt column.
  public func keepsGenmoji() async throws -> Bool {
    try await database.columns(of: "ZMANAGEDSTICKER")
      .contains { $0.uppercased() == "ZSANITIZEDPROMPT" }
  }

  /// Every Genmoji in the store, newest first, each listed once.
  ///
  /// The whole library in one read rather than a page: grouping a saved row with its recent
  /// copy cannot be done inside `LIMIT`, and the rows are metadata, a few hundred bytes each.
  /// The caller pages what comes back.
  public func genmoji() async throws -> [GenmojiRow] {
    guard try await keepsGenmoji() else { return [] }
    let columns = try await genmojiColumns()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT \(columns.sticker) FROM ZMANAGEDSTICKER s
          WHERE s.ZSANITIZEDPROMPT IS NOT NULL AND s.ZSANITIZEDPROMPT <> ''
          """
      )
      let stored = rows.mapRows(in: .stickerStore, StoredGenmoji.init).compactMap { $0 }
      return Self.group(
        stored,
        renditions: try Self.genmojiRenditions(
          db, stickerKeys: stored.map(\.key), columns: columns.representation))
    }
  }

  /// One Genmoji by its content identifier, dashed or bare hex. Nil when there is none.
  ///
  /// Matched on the external URI, which is indexed and is what a recent copy names it by, and
  /// on the row identifier, which is what the saved row itself carries.
  public func genmoji(identifier: String) async throws -> GenmojiRow? {
    guard let hex = Self.hex(identifier), let dashed = Self.uuid(hex),
      let blob = Self.blob(hex), try await keepsGenmoji()
    else { return nil }
    let columns = try await genmojiColumns()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT \(columns.sticker) FROM ZMANAGEDSTICKER s
          WHERE s.ZSANITIZEDPROMPT IS NOT NULL AND s.ZSANITIZEDPROMPT <> ''
            AND (s.ZEXTERNALURI = ? OR s.ZIDENTIFIER = ?)
          """,
        arguments: [Self.userURIPrefix + dashed, blob]
      )
      let stored = rows.mapRows(in: .stickerStore, StoredGenmoji.init).compactMap { $0 }
      return Self.group(
        stored,
        renditions: try Self.genmojiRenditions(
          db, stickerKeys: stored.map(\.key), columns: columns.representation)
      ).first { $0.identifier == dashed }
    }
  }

  /// The bytes of one rendition, as the store holds them: a HEIC, on every row measured.
  public func genmojiBytes(of rendition: GenmojiRendition) async throws -> Data? {
    try await database.read { db in
      let row = try Row.fetchOne(
        db, sql: "SELECT r.ZDATA AS data FROM ZMANAGEDREPRESENTATION r WHERE r.Z_PK = ?",
        arguments: [rendition.key])
      guard let data = row?.mapped(in: .stickerStore, { $0.optional("data") as Data? }),
        !data.isEmpty
      else { return nil }
      return data
    }
  }

  // MARK: - Columns

  private static let genmojiStickerColumns: [(String, String)] = [
    ("pk", "Z_PK"), ("type", "ZTYPE"), ("identifier", "hex(ZIDENTIFIER)"),
    ("externalURI", "ZEXTERNALURI"), ("prompt", "ZSANITIZEDPROMPT"),
    ("language", "ZPROMPTPRIMARYLANGUAGEIDENTIFIER"),
    ("createdAt", "ZCREATIONDATE"), ("lastUsedAt", "ZLASTUSEDDATE"),
  ]

  private static let genmojiRenditionColumns: [(String, String)] = [
    ("key", "Z_PK"), ("sticker", "ZSTICKER"), ("identifier", "hex(ZIDENTIFIER)"),
    ("role", "ZROLE"), ("uti", "ZUTI"), ("width", "ZSIZE_W"), ("height", "ZSIZE_H"),
    ("byteCount", "ZBYTECOUNT"),
  ]

  /// Filtered by what the tables carry, as every sticker query is. Not memoised: two
  /// `PRAGMA table_info` reads are nothing beside the read they precede.
  private func genmojiColumns() async throws -> (sticker: String, representation: String) {
    let sticker = Set(
      try await database.columns(of: "ZMANAGEDSTICKER").map { $0.uppercased() })
    let representation = Set(
      try await database.columns(of: "ZMANAGEDREPRESENTATION").map { $0.uppercased() })
    return (
      Self.selectList(Self.genmojiStickerColumns, available: sticker, alias: "s"),
      Self.selectList(Self.genmojiRenditionColumns, available: representation, alias: "r")
    )
  }

  // MARK: - Assembly

  /// A Genmoji row of the store, before grouping.
  struct StoredGenmoji: Equatable {
    let key: Int
    let shelf: StickerShelf
    let identifier: String
    let externalURI: String
    let prompt: String
    let language: String?
    let createdAt: Date?
    let lastUsedAt: Date?

    init(
      key: Int, shelf: StickerShelf, identifier: String, externalURI: String, prompt: String,
      language: String? = nil, createdAt: Date? = nil, lastUsedAt: Date? = nil
    ) {
      self.key = key
      self.shelf = shelf
      self.identifier = identifier
      self.externalURI = externalURI
      self.prompt = prompt
      self.language = language
      self.createdAt = createdAt
      self.lastUsedAt = lastUsedAt
    }

    init?(_ r: MappedRow) {
      guard let key: Int = r.optional("pk"),
        let identifier = StickerRepository.uuid(r.optional("identifier")),
        let shelf = StickerShelf.shelf(forStoredType: r.optional("type") ?? -1),
        let prompt = StickerRepository.nonEmpty(r.optional("prompt"))
      else { return nil }
      self.init(
        key: key, shelf: shelf, identifier: identifier,
        externalURI: r.optional("externalURI") ?? "", prompt: prompt,
        language: StickerRepository.nonEmpty(r.optional("language")),
        createdAt: StickerRepository.coreDataDate(r.optional("createdAt")),
        lastUsedAt: StickerRepository.coreDataDate(r.optional("lastUsedAt")))
    }

    /// The Genmoji this row belongs to: the UUID its external URI names, which on the saved
    /// row is its own identifier, or the row's own identifier for a URI of another shape.
    var contentIdentifier: String {
      guard externalURI.hasPrefix(StickerRepository.userURIPrefix),
        let hex = StickerRepository.hex(
          String(externalURI.dropFirst(StickerRepository.userURIPrefix.count))),
        let dashed = StickerRepository.uuid(hex)
      else { return identifier }
      return dashed
    }
  }

  /// One row per Genmoji, newest first.
  ///
  /// The saved row speaks for the group: its prompt, its renditions. A Genmoji that is only a
  /// recent speaks through its newest row. The dates span every row, so `lastUsedAt` is the
  /// recent copy's when there is one.
  static func group(
    _ rows: [StoredGenmoji], renditions: [Int: [GenmojiRendition]]
  ) -> [GenmojiRow] {
    let groups = Dictionary(grouping: rows, by: \.contentIdentifier)
    let assembled = groups.map { identifier, members -> GenmojiRow in
      // Saved first, then newest first: the order `stickerIdentifiers` reports.
      let ordered = members.sorted {
        ($0.shelf == .saved ? 0 : 1, -$0.key) < ($1.shelf == .saved ? 0 : 1, -$1.key)
      }
      let source = ordered[0]
      let sizes = ordered.lazy.compactMap { renditions[$0.key] }.first { !$0.isEmpty } ?? []
      return GenmojiRow(
        identifier: identifier,
        description: source.prompt,
        languageIdentifier: source.language ?? ordered.lazy.compactMap(\.language).first,
        createdAt: members.compactMap(\.createdAt).min(),
        lastUsedAt: members.compactMap(\.lastUsedAt).max(),
        shelves: Set(members.map(\.shelf)),
        stickerIdentifiers: ordered.map(\.identifier),
        renditions: sizes.sorted { ($0.width, $0.key) < ($1.width, $1.key) })
    }
    return assembled.sorted {
      switch ($0.createdAt, $1.createdAt) {
      case (let left?, let right?) where left != right: left > right
      case (.some, .none): true
      case (.none, .some): false
      default: $0.identifier < $1.identifier
      }
    }
  }

  private static func genmojiRenditions(
    _ db: Database, stickerKeys: [Int], columns: String
  ) throws -> [Int: [GenmojiRendition]] {
    guard !stickerKeys.isEmpty else { return [:] }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT \(columns) FROM ZMANAGEDREPRESENTATION r
        WHERE r.ZSTICKER IN (\(SQLPlaceholders.list(stickerKeys.count)))
        """,
      arguments: StatementArguments(stickerKeys)
    )
    let renditions = rows.mapRows(in: .stickerStore) { r -> (Int, GenmojiRendition)? in
      guard let sticker: Int = r.optional("sticker"), let key: Int = r.optional("key")
      else { return nil }
      return (
        sticker,
        GenmojiRendition(
          identifier: uuid(r.optional("identifier")) ?? "",
          role: r.optional("role") ?? "",
          uti: r.optional("uti") ?? "",
          width: Int(((r.optional("width") as Double?) ?? 0).rounded()),
          height: Int(((r.optional("height") as Double?) ?? 0).rounded()),
          byteCount: r.optional("byteCount") ?? 0,
          key: key)
      )
    }
    var byKey: [Int: [GenmojiRendition]] = [:]
    for case (let sticker, let rendition)? in renditions {
      byKey[sticker, default: []].append(rendition)
    }
    return byKey
  }

  /// The 16 bytes of a UUID blob, for matching an indexed `ZIDENTIFIER` without `hex()`.
  static func blob(_ hex: String) -> Data? {
    guard hex.count == 32 else { return nil }
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return Data(bytes)
  }
}
