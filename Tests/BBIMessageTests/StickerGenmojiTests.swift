//  StickerGenmojiTests
//  Telling Genmoji apart in the sticker store, and listing each one once.
//
//  The fixture is shaped on the measured macOS 27 store (see `StickerRepository+Genmoji`), with
//  only the columns the queries name: a saved Genmoji and the recent copy that points back at
//  it, a Genmoji that is only a recent, a Genmoji Messages made with one rendition, and two
//  rows that must NOT be listed: a Live Sticker that carries a prompt language and no prompt,
//  and an emoji sticker. A second fixture has no prompt column at all, which is Sonoma.

import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Genmoji in the sticker store")
struct StickerGenmojiTests {

  static let saved = "11111111-2222-4333-8444-555555555555"
  static let recentOnly = "66666666-7777-4888-9999-AAAAAAAAAAAA"
  static let single = "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"
  /// The recent copy's OWN identifier, which names the row and not the Genmoji.
  static let recentCopy = "0A0A0A0A-0B0B-4C0C-8D0D-0E0E0E0E0E0E"

  static func store(withPrompts: Bool = true) throws -> (
    path: String, repository: StickerRepository
  ) {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-genmoji-\(UUID().uuidString).sqlite").path
    let queue = try DatabaseQueue(path: path)
    let promptColumns =
      withPrompts ? ", ZSANITIZEDPROMPT VARCHAR, ZPROMPTPRIMARYLANGUAGEIDENTIFIER VARCHAR" : ""
    try queue.write { db in
      try db.execute(
        sql: """
          CREATE TABLE ZMANAGEDSTICKER (
              Z_PK INTEGER PRIMARY KEY, ZTYPE INTEGER, ZIDENTIFIER BLOB, ZEXTERNALURI VARCHAR,
              ZCREATIONDATE FLOAT, ZLASTUSEDDATE FLOAT\(promptColumns)
          );
          CREATE TABLE ZMANAGEDREPRESENTATION (
              Z_PK INTEGER PRIMARY KEY, ZSTICKER INTEGER, ZIDENTIFIER BLOB, ZROLE VARCHAR,
              ZUTI VARCHAR, ZSIZE_W FLOAT, ZSIZE_H FLOAT, ZBYTECOUNT INTEGER, ZDATA BLOB
          );
          """)
      guard withPrompts else {
        try db.execute(
          sql: """
            INSERT INTO ZMANAGEDSTICKER VALUES
              (1, 0, X'11111111222243338444555555555555',
               'sticker:///emoji/identifier/x', 100, 100);
            """)
        return
      }
      try db.execute(
        sql: """
          INSERT INTO ZMANAGEDSTICKER VALUES
            -- A saved Genmoji, and its recent copy pointing back at it a second later.
            (1, 1, X'11111111222243338444555555555555',
             'sticker:///user/identifier/11111111-2222-4333-8444-555555555555',
             1000, 1000, 'a teal circle', 'en_US'),
            (2, 0, X'0A0A0A0A0B0B4C0C8D0D0E0E0E0E0E0E',
             'sticker:///user/identifier/11111111-2222-4333-8444-555555555555',
             1001, 5000, 'a teal circle', 'en_US'),
            -- Only a recent: its URI names itself.
            (3, 0, X'66666666777748889999AAAAAAAAAAAA',
             'sticker:///user/identifier/66666666-7777-4888-9999-AAAAAAAAAAAA',
             3000, 3000, 'a blue square', NULL),
            -- Messages made this one: the 1024 still alone.
            (4, 1, X'BBBBBBBBCCCC4DDD8EEEFFFFFFFFFFFF',
             'sticker:///user/identifier/BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF',
             2000, 2000, 'a green star', 'en_GB'),
            -- A Live Sticker: a language and no prompt. Not a Genmoji.
            (5, 1, X'12121212343456567878909090909090',
             'sticker:///user/identifier/12121212-3434-5656-7878-909090909090',
             4000, 4000, '', 'en_US'),
            -- An emoji sticker. Not a Genmoji.
            (6, 0, X'13131313343456567878909090909091',
             'sticker:///emoji/identifier/x', 4500, 4500, NULL, NULL);
          INSERT INTO ZMANAGEDREPRESENTATION VALUES
            (10, 1, X'AAAA0000000000000000000000000040', 'com.apple.stickers.role.stillVariant_40',
             'public.heic', 40, 40, 4, X'00000001'),
            (11, 1, X'AAAA0000000000000000000000000096', 'com.apple.stickers.role.keyboard',
             'public.heic', 96, 96, 4, X'00000002'),
            (12, 1, X'AAAA0000000000000000000000001024', 'com.apple.stickers.role.still',
             'public.heic', 1024, 1024, 4, X'00000003'),
            (13, 1, X'AAAA0000000000000000000000000960', 'com.apple.stickers.role.stillVariant_96',
             'public.heic', 96, 96, 4, X'00000004'),
            -- The recent copy shares the saved row's renditions.
            (20, 2, X'AAAA0000000000000000000000000040', 'com.apple.stickers.role.stillVariant_40',
             'public.heic', 40, 40, 4, X'00000001'),
            (30, 3, X'BBBB0000000000000000000000000320', 'com.apple.stickers.role.stillVariant_320',
             'public.heic', 320, 320, 4, X'00000005'),
            (40, 4, X'CCCC0000000000000000000000001024', 'com.apple.stickers.role.still',
             'public.heic', 1024, 1024, 4, X'00000006');
          """)
    }
    try queue.close()
    return (path, StickerRepository(database: try ReadOnlyDatabase(path: path)))
  }

  @Test("Each Genmoji is listed once, newest first, and nothing else is listed")
  func listsGenmojiOnce() async throws {
    let (path, repository) = try Self.store()
    defer { try? FileManager.default.removeItem(atPath: path) }

    #expect(try await repository.keepsGenmoji())
    let listed = try await repository.genmoji()
    #expect(listed.map(\.identifier) == [Self.recentOnly, Self.single, Self.saved])
  }

  @Test("A saved Genmoji and its recent copy are one entry that the saved row speaks for")
  func savedAndRecentAreOne() async throws {
    let (path, repository) = try Self.store()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let genmoji = try #require(try await repository.genmoji().first { $0.identifier == Self.saved })
    #expect(genmoji.description == "a teal circle")
    #expect(genmoji.languageIdentifier == "en_US")
    #expect(genmoji.shelves == [.saved, .recent])
    #expect(genmoji.stickerIdentifiers == [Self.saved, Self.recentCopy])
    // The saved row's renditions, smallest first, and the keyboard and still variant both kept.
    #expect(genmoji.renditions.map(\.width) == [40, 96, 96, 1024])
    // The dates span both rows: made with the saved one, last used through the recent one.
    #expect(genmoji.createdAt == Date(timeIntervalSinceReferenceDate: 1000))
    #expect(genmoji.lastUsedAt == Date(timeIntervalSinceReferenceDate: 5000))
  }

  @Test("One is found by its content identifier in either spelling, and not by a row's own")
  func lookupByContentIdentifier() async throws {
    let (path, repository) = try Self.store()
    defer { try? FileManager.default.removeItem(atPath: path) }

    #expect(try await repository.genmoji(identifier: Self.saved)?.identifier == Self.saved)
    let bare = Self.saved.replacingOccurrences(of: "-", with: "").lowercased()
    #expect(try await repository.genmoji(identifier: bare)?.identifier == Self.saved)
    #expect(try await repository.genmoji(identifier: Self.recentOnly)?.shelves == [.recent])
    // The recent copy's row identifier names the row, not the Genmoji.
    #expect(try await repository.genmoji(identifier: Self.recentCopy) == nil)
    // The Live Sticker has no prompt, so it is not a Genmoji however it is asked for.
    #expect(
      try await repository.genmoji(identifier: "12121212-3434-5656-7878-909090909090") == nil)
    #expect(try await repository.genmoji(identifier: "not-an-identifier") == nil)
  }

  @Test("A rendition's bytes are read by its key")
  func readsBytes() async throws {
    let (path, repository) = try Self.store()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let genmoji = try #require(try await repository.genmoji(identifier: Self.single))
    let rendition = try #require(genmoji.renditions.first)
    #expect(try await repository.genmojiBytes(of: rendition) == Data([0, 0, 0, 6]))
  }

  @Test("A store with no prompt column keeps no Genmoji, and says so rather than failing")
  func sonomaKeepsNone() async throws {
    let (path, repository) = try Self.store(withPrompts: false)
    defer { try? FileManager.default.removeItem(atPath: path) }

    #expect(try await !repository.keepsGenmoji())
    #expect(try await repository.genmoji().isEmpty)
    #expect(try await repository.genmoji(identifier: Self.saved) == nil)
  }

  @Test("A UUID's hex becomes its sixteen bytes, and anything else is refused")
  func blobs() {
    #expect(
      StickerRepository.blob("000102030405060708090A0B0C0D0E0F") == Data(0..<16))
    #expect(StickerRepository.blob("00") == nil)
    #expect(StickerRepository.blob("ZZ0102030405060708090A0B0C0D0E0F") == nil)
  }
}
