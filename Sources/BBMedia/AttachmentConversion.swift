//  AttachmentConversion
//  Serving an attachment in a format the client can actually open.
//
//  iMessage stores what the sending device produced: an iPhone photo is HEIC and a voice note
//  is CAF. Most clients can display neither. The Node server converts both on download unless
//  the caller asks for `original=true`, so every shipped client depends on this happening:
//  an Android client asking for a photo would otherwise get a HEIC it cannot render.
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

    /// The three values `?quality=` accepts.
    ///
    /// A NAMED SET, not a number, because that is the v1 wire: the reference validates
    /// `quality: "string|in:good,better,best"` (`validators/attachmentValidator.ts:20`) and
    /// rejects anything else with a 400 before the route runs. Parsing it as a `Double`
    /// instead, which is what this took before, was wrong twice over. A client sending the
    /// only spelling the reference accepts had its request silently ignored, because
    /// `Double("good")` is nil; and `?quality=inf` parsed, reached `Int(quality * 100)`,
    /// and trapped the process, so any authenticated client could stop the server with one
    /// URL.
    ///
    /// In the reference these select Electron's resampling quality for the resize rather
    /// than a compression ratio. We are not Electron, so they map to the JPEG compression
    /// quality that produces a comparable result; what a client can observe is which
    /// spellings are accepted, and that is preserved exactly.
    public enum Quality: String, Sendable, Equatable, CaseIterable {
      case good
      case better
      case best

      /// What `kCGImageDestinationLossyCompressionQuality` is given.
      var compressionQuality: Double {
        switch self {
        case .good: 0.7
        case .better: 0.85
        case .best: 1.0
        }
      }

      /// The reference's own wording, so a client that surfaces the error to a user sees
      /// the string it has always seen.
      public static var rejectionMessage: String {
        "Invalid quality specified! Must be one of: "
          + Quality.allCases.map(\.rawValue).joined(separator: ", ")
      }
    }

    /// `original=true`: hand back exactly what iMessage stored, converting nothing.
    public var original: Bool
    public var quality: Quality?
    public var width: Int?
    public var height: Int?

    public init(
      original: Bool = false,
      quality: Quality? = nil,
      width: Int? = nil,
      height: Int? = nil
    ) {
      self.original = original
      self.quality = quality
      self.width = width
      self.height = height
    }

    /// Whether anything about this request differs from just serving the file.
    ///
    /// `quality` alone counts, and therefore decodes the image at FULL resolution for a
    /// re-encode that produces a similarly sized file. That looks like waste and is the
    /// contract: the reference builds `opts` from whichever of quality, width and height
    /// were given and calls `image.resize(opts)`, so quality with no dimension resizes to
    /// the original size and re-encodes. Capping the edge here -- 2048 was proposed -- would
    /// hand a client asking for `?quality=good` a smaller image than every Node server
    /// returns for the same request.
    ///
    /// So it stays, and the cost is bounded elsewhere: `ConversionGate` limits how many of
    /// these run at once, and the result is cached on disk per requested variant.
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
  /// How many conversions may decode at once. Shared by every instance by default; injectable
  /// so a test can bound it to something it can observe. See `ConversionGate`.
  private let gate: ConversionGate
  private let logger: Logger

  public init(
    cacheDirectory: URL? = nil,
    sweepInterval: Duration = .seconds(3600),
    logger: Logger = Logger(label: "bluebubbles.attachments.cache")
  ) {
    self.init(
      cacheDirectory: cacheDirectory, sweepInterval: sweepInterval, gate: .shared, logger: logger)
  }

  init(
    cacheDirectory: URL? = nil,
    sweepInterval: Duration = .seconds(3600),
    gate: ConversionGate,
    logger: Logger = Logger(label: "bluebubbles.attachments.cache")
  ) {
    self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
    self.sweepGate = IntervalGate(interval: sweepInterval)
    self.gate = gate
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
  /// delivered as-is: the client may well cope, and refusing to serve it at all turns a
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
    let quality = options.quality?.compressionQuality ?? 0.85

    // The variant is keyed by the NAME, not the number it maps to: the name is what the
    // client asked for, and it stays stable if a mapping is ever retuned. A retune would
    // otherwise silently serve everyone the old file out of cache.
    let destination = cachePath(
      for: path,
      variant: "q\(options.quality?.rawValue ?? "default")-d\(maximumDimension ?? 0)",
      extension: "jpg"
    )
    if let cached = existingCache(destination, sourcePath: path) {
      return Resolved(path: cached, mimeType: "image/jpeg")
    }

    do {
      try FileManager.default.createDirectory(
        at: cacheDirectory, withIntermediateDirectories: true
      )
      // Gated, because this is the most expensive thing the server does and it had no
      // bound at all. The cache lookup above is deliberately OUTSIDE the gate: a hit is a
      // stat and should never queue behind someone else's decode.
      try await gate.run {
        try await writingAtomically(to: destination) { temporary in
          // OFF the cooperative pool. `ImageConverter.convert` is synchronous, CPU-bound,
          // and has no suspension point in it: decoding a 12-megapixel HEIC, scaling it and
          // re-encoding. Run inline it occupies a cooperative thread for the whole of that
          // -- 48ms here with hardware decode, an estimated half to one second on a
          // pre-Kaby-Lake Intel with none -- and the runtime's pool is sized to the core
          // count, so on a dual-core Mac two of these are the entire pool.
          //
          // The gate above is what bounds how many run at once; this only decides WHERE.
          try await Self.offTheCooperativePool {
            try ImageConverter.convert(
              source: path,
              destination: temporary,
              to: .jpeg,
              quality: quality,
              maximumDimension: maximumDimension
            )
          }
        }
      }
      await sweepIfDue()
      return Resolved(path: destination, mimeType: "image/jpeg")
    } catch {
      logConversionFailure(kind: "image", mimeType: mimeType, error: error)
      return nil
    }
  }

  /// Where synchronous, CPU-bound conversion work runs.
  ///
  /// Concurrent on purpose: `ConversionGate` already bounds the depth, so this queue only
  /// needs to not be the cooperative pool. `.utility` because a conversion is work somebody
  /// is waiting for but not watching, and it must not outrank the request that asked for it.
  private static let conversionQueue = DispatchQueue(
    label: "bluebubbles.attachments.conversion", qos: .utility, attributes: .concurrent)

  /// The queue label conversion work actually runs on.
  ///
  /// For the test that asserts it is not the cooperative pool. Asked of the dispatch queue
  /// itself rather than inferred, and exercised through the same helper the converters use,
  /// so it cannot drift from what they do.
  static func queueLabelForCurrentConversionWork() async -> String {
    (try? await offTheCooperativePool {
      String(cString: __dispatch_queue_get_label(nil))
    }) ?? "unknown"
  }

  /// Runs synchronous work on `conversionQueue` and awaits its result.
  private static func offTheCooperativePool<T: Sendable>(
    _ body: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      conversionQueue.async {
        continuation.resume(with: Result { try body() })
      }
    }
  }

  /// Runs a conversion into a UNIQUE temporary file and moves it into place when it is
  /// whole.
  ///
  /// The converters write straight to their destination (`CGImageDestinationCreateWithURL`
  /// and `AVAssetExportSession` both do), and the destination is derived from the source and
  /// the requested variant, so it is the SAME path for every caller asking for the same
  /// thing. Two concurrent downloads of one attachment therefore both missed the cache and
  /// both wrote the same file, and a third arriving mid-write found it present, passed the
  /// existence-and-mtime check, and was served a half-written JPEG. On a slow tunnel with a
  /// thirty-minute timeout, several requests for one image is the normal case rather than a
  /// race somebody has to arrange.
  ///
  /// A rename within one directory is atomic, so a reader sees either the previous file or
  /// the complete new one and never a partial. The loser of a race replaces the winner's
  /// file with an identical one, which is wasted work and not a wrong answer.
  private func writingAtomically(
    to destination: String,
    _ convert: (String) async throws -> Void
  ) async throws {
    let temporary = destination + ".partial-\(UUID().uuidString)"
    do {
      try await convert(temporary)
    } catch {
      try? FileManager.default.removeItem(atPath: temporary)
      throw error
    }
    // `replaceItemAt` handles the destination already existing, which it will whenever two
    // requests raced; `moveItem` throws there.
    _ = try FileManager.default.replaceItemAt(
      URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: temporary)
    )
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
      try await gate.run {
        try await writingAtomically(to: destination) { temporary in
          try await AudioConverter.convert(source: path, destination: temporary)
        }
      }
      await sweepIfDue()
      return Resolved(path: destination, mimeType: "audio/x-m4a")
    } catch {
      logConversionFailure(kind: "audio", mimeType: mimeType, error: error)
      return nil
    }
  }

  /// The original is served instead, which is the right fallback and the wrong thing to
  /// do silently: a client that asked for a JPEG and got HEIC shows a broken image. The
  /// type and the error, never the path: attachment file names are whatever the sender
  /// called them.
  private func logConversionFailure(kind: String, mimeType: String, error: any Error) {
    logger.debug(
      "Attachment conversion failed; serving the original",
      metadata: [
        "kind": .string(kind),
        "mimeType": .string(mimeType),
        "error": .string(String(describing: error)),
      ])
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
  /// Three `stat` calls where there were two `attributesOfItem` calls and an existence check.
  ///
  /// `attributesOfItem` builds a whole `FileAttributeKey` dictionary -- owner, permissions,
  /// inode, type, a dozen boxed values -- to answer one question about one date. Measured at
  /// 24.8µs against 0.59µs for `lstat`, and this runs twice per download, on the path a
  /// client hits once per image in a conversation.
  private func existingCache(_ destination: String, sourcePath: String) -> String? {
    guard let cached = Self.modificationTime(of: destination),
      let source = Self.modificationTime(of: sourcePath),
      cached >= source
    else { return nil }
    return destination
  }

  /// A file's modification time, or nil if it is not a regular file.
  ///
  /// The existence check is folded in: `stat` failing IS "not there", so the separate
  /// `fileExists` call this replaced was a third trip through the filesystem to learn
  /// something the next call was about to find out anyway.
  static func modificationTime(of path: String) -> Date? {
    var status = stat()
    guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
    return Date(
      timeIntervalSince1970: Double(status.st_mtimespec.tv_sec)
        + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000)
  }

  // MARK: - Eviction

  /// How much converted output may sit on disk before the oldest is dropped.
  ///
  /// A cache with no ceiling is a disk leak with a slow fuse, and this is the fastest-growing
  /// store the server owns: one entry per image or voice note any client ever fetches, plus a
  /// separate entry per requested size of the same photo.
  ///
  /// Two gigabytes is chosen to be generous rather than tight, because a miss costs a
  /// re-encode rather than a lost file: every entry is reproducible from an attachment that
  /// is still on disk. If this ever needs to be tunable it should become a `Setting<Int>`;
  /// it is a constant while there is no evidence anyone needs to move it.
  static let sizeBudget = 2 * 1024 * 1024 * 1024

  /// Dropped regardless of the size budget. A conversion nobody has asked for in a month is
  /// one the next request can pay for again.
  static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

  /// Brings the cache directory back inside its budget.
  ///
  /// Age first, then size, oldest first. "Oldest" is by modification date, which is set when
  /// the conversion is written, so this is oldest-first rather than least-recently-used. The
  /// difference would matter for a cache that is expensive to miss; this one costs a
  /// re-encode, and true LRU would mean writing to the file on every cache HIT to bump its
  /// timestamp, which is a worse trade on the hardware this targets.
  ///
  /// **Only files this type wrote are considered.** The name has to match what `cachePath`
  /// produces (sixteen hex digits and a known extension) because `cacheDirectory` is
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
  /// converting anything does no work, and the cache only grows when a conversion is
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
