//  StickerRepositoryTests
//  The sticker store's reader: identifiers, shelves, content types, and bad cells.
//
//  The queries' fidelity to Apple's schema is exercised against a live Mac rather than here:
//  there is no fixture `stickers.stickerdb`, and reproducing the Core Data + CloudKit schema
//  Apple owns would pin the shape of the fake rather than of the real thing. Two things ARE
//  testable in isolation. Everything an identifier or an external URI goes through on its
//  way in and out, which is where the bugs were: a client sending a dashed UUID against a
//  column holding raw blob bytes has to normalise somewhere. And what a cell that does not
//  hold its column's type does to a read, which needs only the columns the queries name.

import BBPersistence
import Foundation
import GRDB
import ImageIO
import Testing

@testable import BBIMessage

@Suite("Sticker store")
struct StickerRepositoryTests {

  /// SQLite does not enforce declared types, and GRDB's typed subscript decodes with `try!`,
  /// so each of these cells ended the process the first time a listing reached its row.
  @Test("A mistyped cell degrades one field or drops one row, never the read")
  func mistypedCellsAreContained() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-stickers-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
      // Only the columns the queries name; the rest are selected as NULL when absent.
      try db.execute(
        sql: """
          CREATE TABLE ZMANAGEDSTICKER (
              Z_PK INTEGER PRIMARY KEY, ZTYPE INTEGER, ZIDENTIFIER BLOB,
              ZEXTERNALURI VARCHAR, ZNAME VARCHAR, ZBYTECOUNT INTEGER, ZLIBRARYINDEX FLOAT
          );
          CREATE TABLE ZMANAGEDREPRESENTATION (
              Z_PK INTEGER PRIMARY KEY, ZSTICKER INTEGER, ZIDENTIFIER BLOB, ZROLE VARCHAR,
              ZUTI VARCHAR, ZSIZE_W FLOAT, ZSIZE_H FLOAT, ZBYTECOUNT INTEGER,
              ZISPREFERRED INTEGER, ZINDEX INTEGER, ZDATA BLOB
          );
          -- Readable throughout.
          INSERT INTO ZMANAGEDSTICKER VALUES
              (1, 1, X'7608FF1D006B4E00B15ADDB5001BCBF6', 'sticker:///user/identifier/a',
               'kept', 10, 3.0);
          -- A name that is a BLOB and not UTF-8, and a byte count that is text.
          INSERT INTO ZMANAGEDSTICKER VALUES
              (2, 0, X'AC20781C5A3140D989313619AA9783C9', 'sticker:///emoji/identifier/b',
               X'FFFE00', 'lots', 2.0);
          -- A shelf that is text: the row cannot be placed, so it is left out.
          INSERT INTO ZMANAGEDSTICKER VALUES
              (3, 'saved', X'0123456789ABCDEF0123456789ABCDEF', 'sticker:///user/identifier/c',
               'lost', 1, 1.0);
          -- A UTI that is a BLOB and a width that is text, beside readable cells.
          INSERT INTO ZMANAGEDREPRESENTATION VALUES
              (1, 1, X'00000000000000000000000000000001', 'com.apple.stickers.role.still',
               X'FF', 'wide', 64.0, 4, 1, 0, X'00010203');
          """)
    }
    try queue.close()

    let repository = StickerRepository(database: try ReadOnlyDatabase(path: path))

    let listed = try await repository.stickers()
    #expect(
      listed.map(\.identifier) == [
        "7608FF1D-006B-4E00-B15A-DDB5001BCBF6", "AC20781C-5A31-40D9-8931-3619AA9783C9",
      ])
    let kept = try #require(listed.first)
    #expect(kept.name == "kept")
    #expect(kept.byteCount == 10)
    let rendition = try #require(kept.representations.first)
    #expect(rendition.uti == "")
    #expect(rendition.width == 0)
    #expect(rendition.height == 64)
    #expect(rendition.isPreferred)

    let damaged = try #require(listed.last)
    #expect(damaged.name == nil)
    #expect(damaged.byteCount == 0)
    #expect(damaged.externalURI == "sticker:///emoji/identifier/b")

    let single = try await repository.sticker(identifier: "AC20781C5A3140D989313619AA9783C9")
    #expect(single?.shelf == .recent)
    #expect(try await repository.sticker(identifier: "0123456789ABCDEF0123456789ABCDEF") == nil)
    #expect(try await repository.counts() == [.saved: 1, .recent: 1])

    // The declared type is unreadable, so the bytes are asked instead.
    let bytes = try #require(
      try await repository.bytes(identifier: "7608FF1D-006B-4E00-B15A-DDB5001BCBF6"))
    #expect(bytes.data == Data([0, 1, 2, 3]))
    #expect(bytes.uti == "public.data")
    #expect(bytes.role == StickerRepresentationRow.stillRole)
  }

  @Test("A dashed UUID and bare hex normalise to the same query value")
  func identifiersNormalise() {
    // The column is a 16-byte BLOB, matched against `hex()`, so both spellings a client
    // might send have to arrive as the same 32 uppercase characters.
    let dashed = "AC20781C-5A31-40D9-8931-3619AA9783C9"
    let bare = "ac20781c5a3140d989313619aa9783c9"
    #expect(StickerRepository.hex(dashed) == "AC20781C5A3140D989313619AA9783C9")
    #expect(StickerRepository.hex(bare) == StickerRepository.hex(dashed))
  }

  @Test("A malformed identifier is rejected rather than queried")
  func malformedIdentifiersAreRejected() {
    // Nil is what turns a bad id into a 404 instead of a query with a nonsense argument.
    #expect(StickerRepository.hex("") == nil)
    #expect(StickerRepository.hex("not-a-uuid") == nil)
    // Right length, wrong alphabet: the case that a length check alone would let through.
    #expect(StickerRepository.hex("ZZ20781C5A3140D989313619AA9783C9") == nil)
    // One character short of a UUID.
    #expect(StickerRepository.hex("AC20781C-5A31-40D9-8931-3619AA9783C") == nil)
  }

  @Test("Blob hex comes back out as a dashed UUID")
  func identifiersRoundTrip() {
    // A client should never see raw blob hex: the identifier it reads is the identifier it
    // sends back, in the shape every other identifier in this API has.
    let hex = "7608FF1D006B4E00B15ADDB5001BCBF6"
    #expect(StickerRepository.uuid(hex) == "7608FF1D-006B-4E00-B15A-DDB5001BCBF6")
    #expect(StickerRepository.hex(StickerRepository.uuid(hex) ?? "") == hex)
    #expect(StickerRepository.uuid("short") == nil)
  }

  @Test("Each shelf maps to exactly one stored type, and back")
  func shelvesMapBothWays() {
    // The mapping was read off a live store (see `StickerShelf`) and then confirmed by
    // donating a sticker, which produced a type-0 row. Pinned so a later reading of the
    // schema cannot silently swap them: `saved` and `recent` are what a client filters on.
    #expect(StickerShelf.recent.storedType == 0)
    #expect(StickerShelf.saved.storedType == 1)
    for shelf in StickerShelf.allCases {
      #expect(StickerShelf.shelf(forStoredType: shelf.storedType) == shelf)
    }
    // A type Apple adds later is not silently folded into one of ours.
    #expect(StickerShelf.shelf(forStoredType: 2) == nil)
    #expect(StickerShelf.shelf(forStoredType: -1) == nil)
  }

  @Test("The store's own path is under the stickersd group container")
  func defaultPathIsTheGroupContainer() {
    let path = StickerRepository.defaultPath(home: URL(fileURLWithPath: "/Users/example"))
    #expect(
      path == "/Users/example/Library/Group Containers/com.apple.stickersd.group"
        + "/Stickers/stickers.stickerdb")
  }

  /// A rendition whose row names no type is served as what its bytes are, not as PNG.
  @Test("A download's type is the row's, else the bytes', else generic data")
  func downloadContentType() throws {
    let png = try pngBytes()
    #expect(StickerRepository.contentType(declared: "public.heic", of: png) == "public.heic")
    #expect(StickerRepository.contentType(declared: nil, of: png) == "public.png")
    #expect(StickerRepository.contentType(declared: "", of: png) == "public.png")
    #expect(StickerRepository.contentType(declared: nil, of: Data("junk".utf8)) == "public.data")
  }

  /// A 1×1 PNG, built rather than committed.
  private func pngBytes() throws -> Data {
    let image = try #require(
      CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )?.makeImage())
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }
}
