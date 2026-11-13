//  GenmojiLibraryInterfaceTests
//  Which stored size an image is served from, what it is converted to, and what a batch
//  answers for identifiers it cannot find.
//
//  The store here holds a real 128-pixel PNG as a rendition, so the resize is asserted on
//  pixels that came out of ImageIO rather than on a size field nobody decoded.

import BBCore
import BBIMessage
import BBInterfaces
import BBPersistence
import BBPrivateAPIContract
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing

@testable import BBInterfaces

@Suite("Genmoji library")
struct GenmojiLibraryInterfaceTests {

  static let known = "11111111-2222-4333-8444-555555555555"
  static let other = "66666666-7777-4888-9999-AAAAAAAAAAAA"
  static let renditionID = "ABCDEF00-0000-4000-8000-00000000000A"

  static func rendition(
    _ width: Int, role: String = "com.apple.stickers.role.still", key: Int
  ) -> GenmojiRendition {
    GenmojiRendition(
      identifier: "R\(key)", role: role, uti: "public.heic", width: width, height: width,
      byteCount: 1, key: key)
  }

  // MARK: - Choosing a rendition

  @Test("The smallest rendition at least the asked size is chosen, so a resize only shrinks")
  func smallestAtLeast() {
    let renditions = [40, 64, 96, 160, 320, 1024].enumerated().map {
      Self.rendition($1, key: $0)
    }
    #expect(GenmojiLibraryInterface.rendition(in: renditions, for: 96)?.width == 96)
    #expect(GenmojiLibraryInterface.rendition(in: renditions, for: 100)?.width == 160)
    #expect(GenmojiLibraryInterface.rendition(in: renditions, for: 1)?.width == 40)
    // Larger than anything stored: the largest there is, never nothing.
    #expect(
      GenmojiLibraryInterface.rendition(in: [Self.rendition(320, key: 1)], for: 1024)?.width
        == 320)
  }

  @Test("A still rendition wins over the keyboard one at the same width")
  func stillOverKeyboard() {
    let keyboard = Self.rendition(96, role: "com.apple.stickers.role.keyboard", key: 1)
    let still = Self.rendition(96, role: "com.apple.stickers.role.stillVariant_96", key: 2)
    #expect(GenmojiLibraryInterface.rendition(in: [keyboard, still], for: 96) == still)
  }

  @Test("A rendition with no width is never chosen")
  func zeroWidthIgnored() {
    #expect(GenmojiLibraryInterface.rendition(in: [Self.rendition(0, key: 1)], for: 96) == nil)
  }

  @Test("Sizes outside the route's range are refused, and absent takes the default")
  func sizeRange() throws {
    #expect(try GenmojiLibraryInterface.validated(size: nil, maximum: 1024) == 320)
    #expect(try GenmojiLibraryInterface.validated(size: 1024, maximum: 1024) == 1024)
    for refused in [0, -1, 1025] {
      #expect(throws: InterfaceError.self) {
        try GenmojiLibraryInterface.validated(size: refused, maximum: 1024)
      }
    }
    #expect(throws: InterfaceError.self) {
      try GenmojiLibraryInterface.validated(size: 321, maximum: 320)
    }
  }

  @Test("Identifiers are canonical whichever spelling arrives")
  func canonicalIdentifiers() {
    let bare = Self.known.replacingOccurrences(of: "-", with: "").lowercased()
    #expect(GenmojiLibraryInterface.canonical(bare) == Self.known)
    #expect(GenmojiLibraryInterface.canonical(Self.known) == Self.known)
    #expect(GenmojiLibraryInterface.canonical("nope") == nil)
  }

  // MARK: - Revision

  @Test("The revision is stable for the same rows and moves when one changes")
  func revision() {
    func row(_ description: String) -> GenmojiRow {
      GenmojiRow(
        identifier: Self.known, description: description, languageIdentifier: "en_US",
        createdAt: Date(timeIntervalSinceReferenceDate: 1), lastUsedAt: nil, shelves: [.saved],
        stickerIdentifiers: [Self.known], renditions: [Self.rendition(96, key: 1)])
    }
    let first = GenmojiLibraryInterface.revision(of: [row("a")])
    #expect(first == GenmojiLibraryInterface.revision(of: [row("a")]))
    #expect(first != GenmojiLibraryInterface.revision(of: [row("b")]))
    #expect(first != GenmojiLibraryInterface.revision(of: []))
    #expect(first.count == 16)
  }

  // MARK: - Against a store

  @Test("No store is an empty library with a reason, not an error")
  func noStore() async throws {
    let library = try await GenmojiLibraryInterface(repository: nil).library()
    #expect(library.genmoji.isEmpty)
    #expect(library.unavailableReason == GenmojiLibraryInterface.absentSentence)
    await #expect(throws: InterfaceError.self) {
      try await GenmojiLibraryInterface(repository: nil).select(identifier: Self.known)
    }
  }

  @Test("A store with no prompt column says this macOS keeps none")
  func noPromptColumn() async throws {
    let store = try Store(withPrompts: false)
    defer { store.remove() }
    let library = try await store.interface.library()
    #expect(library.genmoji.isEmpty)
    #expect(library.unavailableReason == GenmojiLibraryInterface.notKeptSentence)
  }

  @Test("PNG is resized to the asked size and never enlarged; HEIC is the stored bytes")
  func renders() async throws {
    let store = try Store()
    defer { store.remove() }

    let small = try await store.interface.image(
      for: try await store.interface.select(identifier: Self.known, size: 64))
    #expect(small.contentType == "image/png")
    #expect((small.width, small.height) == (64, 64))
    #expect(Self.pixelWidth(of: small.data) == 64)

    let asked = try await store.interface.select(identifier: Self.known, size: 512)
    let large = try await store.interface.image(for: asked)
    #expect(large.width == 128)
    #expect(asked.tag == "\(Self.known)-\(Self.renditionID)-512-png")

    let original = try await store.interface.select(
      identifier: Self.known, size: 64, format: .heic)
    #expect(original.tag == "\(Self.known)-\(Self.renditionID)-heic")
    let stored = try await store.interface.image(for: original)
    #expect(stored.data == store.png)
    #expect(stored.width == 128)
  }

  @Test("An unknown Genmoji is not found")
  func unknown() async throws {
    let store = try Store()
    defer { store.remove() }
    await #expect(throws: InterfaceError.self) {
      try await store.interface.select(identifier: Self.other)
    }
  }

  @Test("A batch answers each Genmoji once, in order, and lists what it could not find")
  func batch() async throws {
    let store = try Store()
    defer { store.remove() }
    let bare = Self.known.replacingOccurrences(of: "-", with: "")
    let batch = try await store.interface.images(
      identifiers: [Self.other, Self.known, bare, "nope"], size: 32)
    #expect(batch.images.map(\.identifier) == [Self.known])
    #expect(batch.images.first?.width == 32)
    #expect(batch.missing == [Self.other, "nope"])
  }

  @Test("A batch refuses no identifiers, too many, and a size above its ceiling")
  func batchLimits() async throws {
    let store = try Store()
    defer { store.remove() }
    await #expect(throws: InterfaceError.self) {
      try await store.interface.images(identifiers: [])
    }
    await #expect(throws: InterfaceError.self) {
      try await store.interface.images(
        identifiers: Array(repeating: Self.known, count: 51))
    }
    await #expect(throws: InterfaceError.self) {
      try await store.interface.images(identifiers: [Self.known], size: 321)
    }
  }

  // MARK: - Deleting

  /// A helper that removes rows from the fixture store the way `stickersd` would, or not at
  /// all, and records what it was asked to remove.
  final class RemovingHelper: StickerLibrary, @unchecked Sendable {
    let path: String
    let removes: Bool
    private(set) var asked: [[String]] = []

    init(path: String, removes: Bool) {
      self.path = path
      self.removes = removes
    }

    func saveSticker(_ request: SaveStickerRequest) async throws -> SavedSticker {
      throw PrivateAPIError.rejectedByMessages(reason: "not under test")
    }

    func removeStickers(identifiers: [String]) async throws {
      asked.append(identifiers)
      guard removes else { return }
      let queue = try DatabaseQueue(path: path)
      try await queue.write { db in
        for identifier in identifiers {
          let hex = identifier.replacingOccurrences(of: "-", with: "")
          try db.execute(
            sql: "DELETE FROM ZMANAGEDSTICKER WHERE hex(ZIDENTIFIER) = ?", arguments: [hex])
        }
      }
      try queue.close()
    }
  }

  @Test("A deletion removes every row of the Genmoji and answers once the store agrees")
  func deletes() async throws {
    let store = try Store()
    defer { store.remove() }
    let helper = RemovingHelper(path: store.path, removes: true)
    let library = try store.interface(stickers: StickerInterface(privateAPI: helper))

    let deleted = try await library.delete(identifier: Self.known)
    #expect(deleted.identifier == Self.known)
    #expect(helper.asked == [[Self.known]])
    #expect(try await library.library().genmoji.isEmpty)
  }

  @Test("A removal the store does not reflect is refused, not reported as done")
  func unconfirmedRemovalIsRefused() async throws {
    let store = try Store()
    defer { store.remove() }
    let helper = RemovingHelper(path: store.path, removes: false)
    let library = try store.interface(
      stickers: StickerInterface(privateAPI: helper),
      confirmation: .every(.milliseconds(1), attempts: 2))

    do {
      _ = try await library.delete(identifier: Self.known)
      Issue.record("a removal that changed nothing was reported as done")
    } catch InterfaceError.declined(_, let reason) {
      #expect(reason == "not_removed")
    }
  }

  @Test("Deleting needs the helper, and an unknown Genmoji is not found before it is asked")
  func deleteRefusals() async throws {
    let store = try Store()
    defer { store.remove() }
    // No helper: the standard refusal, never a silent success.
    await #expect(throws: (any Error).self) {
      try await store.interface.delete(identifier: Self.known)
    }
    let helper = RemovingHelper(path: store.path, removes: true)
    await #expect(throws: InterfaceError.self) {
      try await (try store.interface(stickers: StickerInterface(privateAPI: helper)))
        .delete(identifier: Self.other)
    }
    #expect(helper.asked.isEmpty)
  }

  // MARK: - Fixture

  static func pixelWidth(of data: Data) -> Int? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return nil }
    return properties[kCGImagePropertyPixelWidth] as? Int
  }

  /// A 128-pixel PNG with a transparent border, as a Genmoji is.
  static func makePNG() throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0, green: 0.5, blue: 0.5, alpha: 1))
    context.fillEllipse(in: CGRect(x: 16, y: 16, width: 96, height: 96))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }

  /// One saved Genmoji whose only rendition is the PNG above, labelled 128 wide.
  struct Store {
    let path: String
    let png: Data
    let interface: GenmojiLibraryInterface

    init(withPrompts: Bool = true) throws {
      path =
        FileManager.default.temporaryDirectory
        .appendingPathComponent("bb-genmoji-library-\(UUID().uuidString).sqlite").path
      png = try GenmojiLibraryInterfaceTests.makePNG()
      let queue = try DatabaseQueue(path: path)
      let prompt = withPrompts ? ", ZSANITIZEDPROMPT VARCHAR" : ""
      let promptValue = withPrompts ? ", 'a teal circle'" : ""
      let data = png
      try queue.write { db in
        try db.execute(
          sql: """
            CREATE TABLE ZMANAGEDSTICKER (
                Z_PK INTEGER PRIMARY KEY, ZTYPE INTEGER, ZIDENTIFIER BLOB,
                ZEXTERNALURI VARCHAR, ZCREATIONDATE FLOAT\(prompt)
            );
            CREATE TABLE ZMANAGEDREPRESENTATION (
                Z_PK INTEGER PRIMARY KEY, ZSTICKER INTEGER, ZIDENTIFIER BLOB, ZROLE VARCHAR,
                ZUTI VARCHAR, ZSIZE_W FLOAT, ZSIZE_H FLOAT, ZBYTECOUNT INTEGER, ZDATA BLOB
            );
            INSERT INTO ZMANAGEDSTICKER VALUES
              (1, 1, X'11111111222243338444555555555555',
               'sticker:///user/identifier/11111111-2222-4333-8444-555555555555', 10\(promptValue));
            """)
        try db.execute(
          sql: """
            INSERT INTO ZMANAGEDREPRESENTATION VALUES
              (7, 1, X'ABCDEF0000004000800000000000000A', 'com.apple.stickers.role.still', 'public.png', 128, 128, ?, ?)
            """,
          arguments: [data.count, data])
      }
      try queue.close()
      interface = GenmojiLibraryInterface(
        repository: StickerRepository(database: try ReadOnlyDatabase(path: path)))
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }

    /// The same store, over a given writer.
    func interface(
      stickers: StickerInterface,
      confirmation: RetrySchedule = GenmojiLibraryInterface.defaultRemovalConfirmation
    ) throws -> GenmojiLibraryInterface {
      GenmojiLibraryInterface(
        repository: StickerRepository(database: try ReadOnlyDatabase(path: path)),
        stickers: stickers, removalConfirmation: confirmation)
    }
  }
}
