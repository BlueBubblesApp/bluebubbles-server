//  GenmojiLibraryInterface
//  The Genmoji this Mac's person has: listing them, and serving their images at a size a
//  client can draw.
//
//  The library is Apple's, not ours. Genmoji live in the sticker store
//  (`StickerRepository+Genmoji.swift` says how they are told apart and why one Genmoji is
//  usually two rows), the saved shelf syncs through iCloud, and on macOS 27 every Genmoji the
//  Image Playground sheet makes for `POST genmoji` lands there by itself. So this reads what
//  Messages' own picker shows and keeps no copy: a second library would drift from the one
//  the person sees on every other device. Reading needs Full Disk Access and no helper.
//
//  Images are served from the stored renditions, which are HEIC files at fixed sizes (40, 64,
//  96, 160, 320 and 1024, though a Genmoji Messages made may have the 1024 alone). A client
//  asks for a size; the smallest stored rendition at least that large is resized to it, so
//  the bytes sent are no larger than asked. PNG is the default because it keeps the
//  transparency and every client can decode it, and HEIC hands back the stored rendition
//  untouched for a client that wants the original.
//
//  Which rendition a request is served from is decided BEFORE any bytes are read
//  (`select`), so a client whose cached copy is current is answered from the metadata alone.
//
//  Deleting is the one write, and the one operation that needs the helper: `stickersd`
//  removes rows only for a process holding the private stickers entitlement, which Messages
//  holds and this server does not. Both rows of a Genmoji go (the saved one and its recent
//  copy), the saved shelf's removal reaches every device through iCloud, and the answer is
//  given only once the store no longer lists it.

import BBCore
import BBIMessage
import BBSystem
import CryptoKit
import Foundation
import UniformTypeIdentifiers

public struct GenmojiLibraryInterface: Sendable {

  /// What the image bytes are sent as.
  public enum Format: String, Sendable, CaseIterable {
    /// Resized to the asked size, transparency kept. The default.
    case png
    /// The stored rendition's own bytes, at its own size.
    case heic
  }

  /// The whole library, newest first.
  public struct Library: Sendable, Equatable {
    public let genmoji: [GenmojiRow]
    /// Why there is nothing to list when the store cannot be read or keeps no Genmoji; nil
    /// when it was read, even if it was empty.
    public let unavailableReason: String?
    /// A digest of everything the listing reports, so a client can tell whether anything
    /// changed without comparing rows. Stable across restarts: it hashes the rows, not the
    /// serialized response, whose key order is not.
    public let revision: String
  }

  /// The stored rendition one image request is served from, and what it will be sent as.
  public struct Selection: Sendable, Equatable {
    public let genmoji: GenmojiRow
    public let rendition: GenmojiRendition
    public let size: Int
    public let format: Format

    /// Names the bytes this selection produces: the same rendition, size and format always
    /// produce the same image, so this is what a client's cached copy is compared against.
    /// The Genmoji's identifier leads, so a rendition the store left unidentified cannot give
    /// two Genmoji the same tag.
    public var tag: String {
      switch format {
      case .png: "\(genmoji.identifier)-\(rendition.identifier)-\(size)-png"
      case .heic: "\(genmoji.identifier)-\(rendition.identifier)-heic"
      }
    }
  }

  public struct Image: Sendable, Equatable {
    /// The Genmoji's identifier, as the listing reports it.
    public let identifier: String
    public let data: Data
    public let contentType: String
    public let width: Int
    public let height: Int

    public init(identifier: String, data: Data, contentType: String, width: Int, height: Int) {
      self.identifier = identifier
      self.data = data
      self.contentType = contentType
      self.width = width
      self.height = height
    }
  }

  /// What a deletion removed.
  public struct Deleted: Sendable, Equatable {
    public let identifier: String
    /// The sticker store's rows that went with it, saved first.
    public let stickerIdentifiers: [String]

    public init(identifier: String, stickerIdentifiers: [String]) {
      self.identifier = identifier
      self.stickerIdentifiers = stickerIdentifiers
    }
  }

  /// What a batch read found, and the identifiers it did not.
  public struct Batch: Sendable, Equatable {
    public let images: [Image]
    /// Identifiers that name no Genmoji here, in the order they were asked for. Reported
    /// rather than refused, because a client syncing its cache asks for what it saw before
    /// and one deleted since is an ordinary answer, not a bad request.
    public let missing: [String]

    public init(images: [Image], missing: [String]) {
      self.images = images
      self.missing = missing
    }
  }

  /// The size a request that names none is served at: the largest rendition a freshly made
  /// Genmoji's glyph carries, and what `POST genmoji` hands back.
  public static let defaultSize = 320
  /// The largest stored rendition.
  public static let maximumSize = 1024
  /// The most images one batch request may ask for.
  public static let maximumBatchCount = 50
  /// The largest size a batch may ask for. Measured on macOS 27.0.1, a 320-pixel Genmoji PNG
  /// is about 130 kilobytes and a 96-pixel one about 15, so a full batch at 320 is about six
  /// and a half megabytes before base64. A 1024-pixel one is several times that, and a client
  /// that wants the full size wants one, from the single-image route.
  public static let maximumBatchSize = 320

  public static let absentSentence =
    "this Mac has no sticker store: either nothing has ever been added to it, or the server "
    + "does not have Full Disk Access to read it"
  public static let notKeptSentence =
    "this macOS keeps no Genmoji in its sticker store: they arrived in macOS Sequoia"

  let repository: StickerRepository?
  let stickers: StickerInterface
  let removalConfirmation: RetrySchedule

  /// How long a deletion waits for the store to stop listing what `stickersd` removed: the
  /// daemon answers once it has saved, and the read-only connection sees the commit on its
  /// next read, so this is slack rather than an expected wait.
  public static let defaultRemovalConfirmation = RetrySchedule.every(
    .milliseconds(250), attempts: 20)

  /// - Parameters:
  ///   - repository: the sticker store, nil when it cannot be opened, which is a library with
  ///     nothing in it rather than an error.
  ///   - stickers: the store's one writer, over whichever helper is connected; without one a
  ///     deletion is the standard helper refusal.
  ///   - removalConfirmation: how often, and how many times, a deletion reads the store back.
  public init(
    repository: StickerRepository?,
    stickers: StickerInterface = StickerInterface(privateAPI: nil),
    removalConfirmation: RetrySchedule = defaultRemovalConfirmation
  ) {
    self.repository = repository
    self.stickers = stickers
    self.removalConfirmation = removalConfirmation
  }

  // MARK: - Listing

  public func library() async throws -> Library {
    guard let repository else { return Self.unavailable(Self.absentSentence) }
    guard try await repository.keepsGenmoji() else {
      return Self.unavailable(Self.notKeptSentence)
    }
    let genmoji = try await repository.genmoji()
    return Library(
      genmoji: genmoji, unavailableReason: nil, revision: Self.revision(of: genmoji))
  }

  private static func unavailable(_ reason: String) -> Library {
    Library(genmoji: [], unavailableReason: reason, revision: revision(of: []))
  }

  /// Sixteen hex characters of a SHA-256 over every field the listing reports, row by row.
  static func revision(of genmoji: [GenmojiRow]) -> String {
    var hasher = SHA256()
    for row in genmoji {
      let line = [
        row.identifier, row.description, row.languageIdentifier ?? "",
        row.createdAt.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "",
        row.lastUsedAt.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "",
        row.shelves.map(\.rawValue).sorted().joined(separator: ","),
        row.stickerIdentifiers.joined(separator: ","),
        row.renditions.map { "\($0.identifier):\($0.width)" }.joined(separator: ","),
      ].joined(separator: "\u{1F}")
      hasher.update(data: Data((line + "\u{1E}").utf8))
    }
    return hasher.finalize().prefix(8).hexString(uppercase: false)
  }

  // MARK: - Images

  /// Which stored rendition `identifier` at `size` is served from.
  ///
  /// - Parameters:
  ///   - size: the longest edge wanted, 1 to `maximumSize`; nil takes `defaultSize`.
  ///   - format: nil takes PNG.
  public func select(
    identifier: String, size: Int? = nil, format: Format? = nil
  ) async throws -> Selection {
    let size = try Self.validated(size: size, maximum: Self.maximumSize)
    guard let repository, let genmoji = try await repository.genmoji(identifier: identifier)
    else {
      throw InterfaceError.notFound("this Mac has no Genmoji with identifier \(identifier)")
    }
    return try Self.selection(of: genmoji, size: size, format: format ?? .png)
  }

  /// The bytes of `selection`, converted where it asks for conversion.
  public func image(for selection: Selection) async throws -> Image {
    guard let repository,
      let stored = try await repository.genmojiBytes(of: selection.rendition)
    else {
      throw InterfaceError.notFound(
        "the image of Genmoji \(selection.genmoji.identifier) is no longer stored")
    }
    return try Self.render(stored, for: selection)
  }

  /// Several Genmoji at one size, in the order asked for.
  ///
  /// One metadata read for the lot, then one byte read per image: the listing is cheap and a
  /// lookup per identifier would be fifty queries where one does.
  public func images(
    identifiers: [String], size: Int? = nil, format: Format? = nil
  ) async throws -> Batch {
    guard !identifiers.isEmpty else {
      throw InterfaceError.invalidRequest("`identifiers` must name at least one Genmoji")
    }
    guard identifiers.count <= Self.maximumBatchCount else {
      throw InterfaceError.invalidRequest(
        "`identifiers` may name at most \(Self.maximumBatchCount) Genmoji; ask again for the rest")
    }
    let size = try Self.validated(size: size, maximum: Self.maximumBatchSize)
    let format = format ?? .png

    let library = try await self.library()
    let byIdentifier = Dictionary(
      library.genmoji.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })

    var images: [Image] = []
    var missing: [String] = []
    var seen: Set<String> = []
    for asked in identifiers {
      // Normalised the way the single route normalises, so bare hex and a dashed UUID name
      // the same Genmoji, and a repeated identifier is answered once.
      guard let canonical = Self.canonical(asked), let genmoji = byIdentifier[canonical] else {
        missing.append(asked)
        continue
      }
      guard seen.insert(canonical).inserted else { continue }
      let selection = try Self.selection(of: genmoji, size: size, format: format)
      do {
        images.append(try await image(for: selection))
      } catch InterfaceError.notFound {
        // Deleted between the listing and the byte read.
        missing.append(asked)
      }
    }
    return Batch(images: images, missing: missing)
  }

  // MARK: - Deleting

  /// Removes a Genmoji from the library, on this Mac and, through iCloud, every other device.
  ///
  /// Every row the store holds for it goes, saved and recent alike, or a recent copy would
  /// keep it in the picker. Answered once the store no longer lists it, read back rather
  /// than taken on the daemon's word; a removal the daemon accepted and the store still
  /// shows after the confirmation window is refused with `not_removed`.
  public func delete(identifier: String) async throws -> Deleted {
    guard let repository, let genmoji = try await repository.genmoji(identifier: identifier)
    else {
      throw InterfaceError.notFound("this Mac has no Genmoji with identifier \(identifier)")
    }
    try await stickers.remove(identifiers: genmoji.stickerIdentifiers)
    let gone = try await poll(removalConfirmation) { _ -> Bool? in
      try await repository.genmoji(identifier: genmoji.identifier) == nil ? true : nil
    }
    guard gone != nil else {
      throw InterfaceError.declined(
        "Messages accepted the removal of Genmoji \(genmoji.identifier), but the sticker "
          + "store still lists it",
        reason: "not_removed")
    }
    return Deleted(identifier: genmoji.identifier, stickerIdentifiers: genmoji.stickerIdentifiers)
  }

  // MARK: - Deciding

  static func validated(size: Int?, maximum: Int) throws -> Int {
    guard let size else { return min(Self.defaultSize, maximum) }
    guard (1...maximum).contains(size) else {
      throw InterfaceError.invalidRequest("`size` must be between 1 and \(maximum) pixels")
    }
    return size
  }

  static func selection(of genmoji: GenmojiRow, size: Int, format: Format) throws -> Selection {
    guard let rendition = rendition(in: genmoji.renditions, for: size) else {
      throw InterfaceError.notFound("Genmoji \(genmoji.identifier) has no stored image")
    }
    return Selection(genmoji: genmoji, rendition: rendition, size: size, format: format)
  }

  /// The smallest rendition at least `size` wide, or the largest there is when none is.
  ///
  /// Smallest-at-least rather than nearest, so a resize only ever shrinks: a 96 served from a
  /// 64 would be blurred. Among equal widths, a `still` role wins over the `keyboard` one,
  /// which the store keeps at the same 96 as a still variant.
  static func rendition(in renditions: [GenmojiRendition], for size: Int) -> GenmojiRendition? {
    let usable = renditions.filter { $0.width > 0 }
    let ordered = usable.sorted {
      ($0.width, isStill($0) ? 0 : 1, $0.key) < ($1.width, isStill($1) ? 0 : 1, $1.key)
    }
    return ordered.first { $0.width >= size } ?? ordered.last
  }

  private static func isStill(_ rendition: GenmojiRendition) -> Bool {
    rendition.role.hasPrefix(StickerRepresentationRow.stillRole)
  }

  static func render(_ stored: Data, for selection: Selection) throws -> Image {
    let rendition = selection.rendition
    switch selection.format {
    case .heic:
      return Image(
        identifier: selection.genmoji.identifier, data: stored,
        contentType: FileTypes.mimeType(forIdentifier: rendition.uti),
        width: rendition.width, height: rendition.height)
    case .png:
      // Never enlarged: a request above the largest rendition gets that rendition's size.
      let converted = try ImageConverter.convert(
        data: stored, to: .png, maximumDimension: min(selection.size, rendition.width))
      return Image(
        identifier: selection.genmoji.identifier, data: converted.data,
        contentType: "image/png", width: converted.width, height: converted.height)
    }
  }

  /// A dashed, uppercase UUID, from either spelling; nil for anything that is not one.
  static func canonical(_ identifier: String) -> String? {
    let stripped = identifier.replacingOccurrences(of: "-", with: "").uppercased()
    guard stripped.count == 32, stripped.allSatisfy(\.isHexDigit) else { return nil }
    let characters = Array(stripped)
    return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
      .map { String(characters[$0]) }.joined(separator: "-")
  }
}
