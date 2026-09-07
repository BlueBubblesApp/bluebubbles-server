//  AttachmentConversion
//  Serving an attachment in a format the client can actually open.
//
//  iMessage stores what the sending device produced: an iPhone photo is HEIC and a voice note
//  is CAF. Most clients can display neither. The Node server converts both on download unless
//  the caller asks for `original=true`, so every shipped client depends on this happening —
//  and `ImageConverter` / `AudioConverter` were built and tested here and wired to nothing, so
//  `attachment.download` returned the raw file and ignored `original`, `quality`, `width` and
//  `height` entirely. An Android client asking for a photo got a HEIC it could not render.
//
//  Conversions are CACHED on disk rather than redone per request. A client fetching a
//  conversation's images requests each one at least once and often several times at different
//  sizes, and re-encoding a 12-megapixel photo per request is exactly the cost the memory
//  budget is trying to keep off an old Mac mini.
//
//  See `.claude/docs/imessage.md` and `.claude/docs/performance.md`.

import BBCore
import BBSystem
import Foundation
import Logging
import UniformTypeIdentifiers

public struct AttachmentConversion: Sendable {

  /// What the caller asked for, parsed from the query string.
  public struct Options: Sendable, Equatable {
    /// `original=true` — hand back exactly what iMessage stored, converting nothing.
    public var original: Bool
    public var quality: Double?
    public var width: Int?
    public var height: Int?

    public init(
      original: Bool = false,
      quality: Double? = nil,
      width: Int? = nil,
      height: Int? = nil
    ) {
      self.original = original
      self.quality = quality
      self.width = width
      self.height = height
    }

    /// Whether anything about this request differs from just serving the file.
    var wantsResize: Bool { quality != nil || width != nil || height != nil }
  }

  /// The file to serve and the type to report for it.
  public struct Resolved: Sendable, Equatable {
    public let path: String
    public let mimeType: String
  }

  private let cacheDirectory: URL
  /// At most one sweep an hour, however many conversions happen in between.
  ///
  /// An actor, so this stays a `let` on a `Sendable` struct that is built once and shared.
  /// The gate is what keeps the budget from costing a directory scan per download.
  private let sweepGate: IntervalGate
  private let logger: Logger

  public init(
    cacheDirectory: URL? = nil,
    sweepInterval: Duration = .seconds(3600),
    logger: Logger = Logger(label: "bluebubbles.attachments.cache")
  ) {
    self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
    self.sweepGate = IntervalGate(interval: sweepInterval)
    self.logger = logger
  }

  public static func defaultCacheDirectory() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(
        "Library/Application Support/bluebubbles-server/ConvertedAttachments"
      )
  }

  /// Picks the file to serve.
  ///
  /// Never throws for a conversion failure. A photo that will not transcode should still be
  /// delivered as-is — the client may well cope, and refusing to serve it at all turns a
  /// cosmetic problem into a missing attachment.
  public func resolve(
    path: String,
    mimeType: String,
    options: Options
  ) async -> Resolved {
    let original = Resolved(path: path, mimeType: mimeType)
    guard !options.original else { return original }
    guard FileManager.default.fileExists(atPath: path) else { return original }

    if FileTypes.isImage(path) {
      // GIFs are excluded, matching Node: converting one to JPEG keeps a single frame
      // and silently turns an animation into a still.
      guard mimeType != "image/gif" else { return original }
      return await convertImage(path: path, mimeType: mimeType, options: options) ?? original
    }

    if FileTypes.isAudio(path) {
      return await convertAudio(path: path, mimeType: mimeType) ?? original
    }

    return original
  }

  // MARK: - Images

  private func convertImage(
    path: String,
    mimeType: String,
    options: Options
  ) async -> Resolved? {
    // Converted when it is a format clients struggle with, OR when a size was asked for.
    // A JPEG with no resize request is already what the caller wants, and re-encoding it
    // would cost CPU and lose quality for nothing.
    let needsFormatChange = !Self.widelySupportedImageTypes.contains(mimeType)
    guard needsFormatChange || options.wantsResize else { return nil }

    // The longest edge, because that is what `ImageConverter` takes and what preserves
    // aspect ratio. Node accepts width and height separately and applies them to a
    // bounding box, so taking the larger matches its result for the common case of one
    // being supplied.
    let maximumDimension = [options.width, options.height].compactMap { $0 }.max()
    let quality = options.quality ?? 0.85

    let destination = cachePath(
      for: path,
      variant: "q\(Int(quality * 100))-d\(maximumDimension ?? 0)",
      extension: "jpg"
    )
    if let cached = existingCache(destination, sourcePath: path) {
      return Resolved(path: cached, mimeType: "image/jpeg")
    }

    do {
      try FileManager.default.createDirectory(
        at: cacheDirectory, withIntermediateDirectories: true
      )
      try ImageConverter.convert(
        source: path,
        destination: destination,
        to: .jpeg,
        quality: quality,
        maximumDimension: maximumDimension
      )
      await sweepIfDue()
      return Resolved(path: destination, mimeType: "image/jpeg")
    } catch {
      return nil
    }
  }

  // MARK: - Audio

  private func convertAudio(path: String, mimeType: String) async -> Resolved? {
    guard !Self.widelySupportedAudioTypes.contains(mimeType) else { return nil }

    let destination = cachePath(for: path, variant: "audio", extension: "m4a")
    if let cached = existingCache(destination, sourcePath: path) {
      return Resolved(path: cached, mimeType: "audio/x-m4a")
    }

    do {
      try FileManager.default.createDirectory(
        at: cacheDirectory, withIntermediateDirectories: true
      )
      try await AudioConverter.convert(source: path, destination: destination)
      await sweepIfDue()
      return Resolved(path: destination, mimeType: "audio/x-m4a")
    } catch {
      return nil
    }
  }

  // MARK: - Cache

  /// A stable name for one source file and one set of conversion options.
  ///
  /// Hashed rather than derived from the path: attachment paths contain spaces, `~` and
  /// unicode, and the variant has to be part of the name or two different sizes of the same
  /// photo would collide on one cache entry.
  private func cachePath(for source: String, variant: String, extension ext: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in (source + "|" + variant).utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return
      cacheDirectory
      .appendingPathComponent(String(format: "%016llx.%@", hash, ext))
      .path
  }

  /// A cached conversion, but only if it is newer than the file it came from.
  ///
  /// The staleness check matters because an attachment path can be REUSED: iMessage
  /// re-downloads a purged attachment to the same location, and serving the old conversion
  /// would hand back the previous image indefinitely.
  private func existingCache(_ destination: String, sourcePath: String) -> String? {
    let manager = FileManager.default
    guard manager.fileExists(atPath: destination),
      let cached = try? manager.attributesOfItem(atPath: destination)[.modificationDate]
        as? Date,
      let source = try? manager.attributesOfItem(atPath: sourcePath)[.modificationDate]
        as? Date,
      cached >= source
    else { return nil }
    return destination
  }

  // MARK: - Eviction

  /// How much converted output may sit on disk before the oldest is dropped.
  ///
  /// A cache with no ceiling is a disk leak with a slow fuse, and this is the fastest-growing
  /// store the server owns: one entry per image or voice note any client ever fetches, plus a
  /// separate entry per requested size of the same photo. Nothing here was ever deleted.
  ///
  /// Two gigabytes is chosen to be generous rather than tight, because a miss costs a
  /// re-encode rather than a lost file — every entry is reproducible from an attachment that
  /// is still on disk. If this ever needs to be tunable it should become a `Setting<Int>`;
  /// it is a constant while there is no evidence anyone needs to move it.
  static let sizeBudget = 2 * 1024 * 1024 * 1024

  /// Dropped regardless of the size budget. A conversion nobody has asked for in a month is
  /// one the next request can pay for again.
  static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

  /// Brings the cache directory back inside its budget.
  ///
  /// Age first, then size, oldest first. "Oldest" is by modification date, which is set when
  /// the conversion is written — so this is oldest-first rather than least-recently-used. The
  /// difference would matter for a cache that is expensive to miss; this one costs a
  /// re-encode, and true LRU would mean writing to the file on every cache HIT to bump its
  /// timestamp, which is a worse trade on the hardware this targets.
  ///
  /// **Only files this type wrote are considered.** The name has to match what `cachePath`
  /// produces — sixteen hex digits and a known extension — because `cacheDirectory` is
  /// injectable, and a sweep that deleted whatever it found would be one bad argument away
  /// from deleting someone's files.
  ///
  /// The limits are parameters rather than only constants so a test can exceed a budget
  /// without writing two gigabytes to disk to do it.
  func sweep(
    sizeBudget: Int = AttachmentConversion.sizeBudget,
    maximumAge: TimeInterval = AttachmentConversion.maximumAge
  ) async {
    let manager = FileManager.default
    guard
      let entries = try? manager.contentsOfDirectory(
        at: cacheDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )
    else { return }

    struct Entry {
      let url: URL
      let modified: Date
      let size: Int
    }

    let now = Date()
    var kept: [Entry] = []
    var removed = 0
    var reclaimed = 0

    for url in entries where Self.isCacheFileName(url.lastPathComponent) {
      guard
        let values = try? url.resourceValues(forKeys: [
          .contentModificationDateKey, .fileSizeKey,
        ]),
        let modified = values.contentModificationDate,
        let size = values.fileSize
      else { continue }

      if now.timeIntervalSince(modified) > maximumAge {
        if (try? manager.removeItem(at: url)) != nil {
          removed += 1
          reclaimed += size
        }
        continue
      }
      kept.append(Entry(url: url, modified: modified, size: size))
    }

    var total = kept.reduce(0) { $0 + $1.size }
    guard total > sizeBudget else {
      Self.log(logger, removed: removed, reclaimed: reclaimed, remaining: total)
      return
    }

    // Oldest first, stopping the moment the total is back inside the budget.
    for entry in kept.sorted(by: { $0.modified < $1.modified }) {
      guard total > sizeBudget else { break }
      guard (try? manager.removeItem(at: entry.url)) != nil else { continue }
      total -= entry.size
      removed += 1
      reclaimed += entry.size
    }
    Self.log(logger, removed: removed, reclaimed: reclaimed, remaining: total)
  }

  private static func log(_ logger: Logger, removed: Int, reclaimed: Int, remaining: Int) {
    guard removed > 0 else { return }
    logger.info(
      "Evicted converted attachments",
      metadata: [
        "removed": .stringConvertible(removed),
        "reclaimedMB": .stringConvertible(reclaimed / (1024 * 1024)),
        "remainingMB": .stringConvertible(remaining / (1024 * 1024)),
      ])
  }

  /// Whether a name is one `cachePath` produced: sixteen hex digits, then a known extension.
  static func isCacheFileName(_ name: String) -> Bool {
    let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, ["jpg", "m4a"].contains(String(parts[1])) else { return false }
    let stem = parts[0]
    return stem.count == 16 && stem.allSatisfy(\.isHexDigit)
  }

  /// Sweeps if the gate is open, without making the caller wait.
  ///
  /// Called after a conversion is written rather than on a timer, so a server that is not
  /// converting anything does no work — and the cache only grows when a conversion is
  /// written, so that is exactly when the budget can be exceeded.
  private func sweepIfDue() async {
    guard case .allowed = await sweepGate.attempt() else { return }
    // Detached from the request: nothing downloading an attachment should wait on a
    // directory scan.
    Task { await self.sweep() }
  }

  /// Types clients handle already. Anything else is converted.
  static let widelySupportedImageTypes: Set<String> = [
    "image/jpeg", "image/jpg", "image/png", "image/gif", "image/webp",
  ]

  static let widelySupportedAudioTypes: Set<String> = [
    "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/aac", "audio/wav",
  ]
}
