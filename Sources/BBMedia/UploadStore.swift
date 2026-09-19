//  UploadStore
//  Where uploads land before they are sent.
//
//  Both upload routes (whole-file multipart and the older base64 chunk stream) write bytes
//  here and hand back a path. Sending is a separate call, which keeps a large file out of the
//  send timeout and lets a client retry the send without re-uploading. The group-icon route
//  writes here too, so an image can be handed to Messages by path.
//
//  In the interfaces layer rather than the handlers because the rules below are decisions, not
//  parsing: where private bytes in transit may live, how a client-chosen transfer id becomes a
//  filename, and what a chunk arriving out of order means.

import BBCore
import Foundation
import Logging

public struct UploadStore: Sendable {

  /// Under the server's own support directory, not the system temporary one: these are the
  /// user's private messages in transit, and a world-readable `/tmp` is the wrong place for
  /// them. Created with owner-only permissions for the same reason.
  public static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/bluebubbles-server/uploads")
  }

  public let directory: URL

  /// At most one sweep an hour, however many uploads arrive in between.
  ///
  /// An actor, so this stays a `let` on a `Sendable` struct that is built once and shared —
  /// the same shape `AttachmentConversion` uses, and for the same reason: the budget must not
  /// cost a directory scan per chunk of a chunked upload.
  private let sweepGate: IntervalGate
  /// The other half of the same decision: bytes since the last sweep. See `SweepVolume`.
  private let sweepVolume: SweepVolume
  /// The per-transfer ceiling in force. See `defaultMaximumTransferBytes`; a parameter so a
  /// test can cross it without writing a gigabyte.
  public let maximumTransferBytes: Int
  private let logger: Logger

  public init(
    directory: URL = UploadStore.defaultDirectory,
    sweepInterval: Duration = .seconds(3600),
    maximumTransferBytes: Int = UploadStore.defaultMaximumTransferBytes,
    sweepByteTrigger: Int = UploadStore.defaultSweepByteTrigger,
    logger: Logger = Logger(label: "bluebubbles.uploads")
  ) {
    self.directory = directory
    self.sweepGate = IntervalGate(interval: sweepInterval)
    self.sweepVolume = SweepVolume(trigger: sweepByteTrigger)
    self.maximumTransferBytes = maximumTransferBytes
    self.logger = logger
  }

  // MARK: - Confining a client-supplied path

  /// Resolves a path a CLIENT named, refusing anything outside the directories it may name.
  ///
  /// The hole this closes: `filePath` in a JSON send body was taken verbatim, and the only
  /// check anywhere was `FileManager.fileExists`. This process holds Full Disk Access, so an
  /// authenticated caller with nothing but `messages:write` could name `chat.db`, a keychain,
  /// an SSH key or the server's own `app.db`, have it staged into Messages' container, and
  /// have it sent to a chat of their choosing. That turns "holds the API password" into
  /// "holds the whole disk", and the refusal message was a filesystem-existence oracle over
  /// every path on the Mac besides.
  ///
  /// **Confining it breaks no client, because the reference never accepted an absolute path.**
  /// `validators/messageValidator.ts:261` joins `part.attachment` — a NAME — onto a fixed
  /// directory, with the comment "Each attachment must have been uploaded prior using the
  /// /attachment/upload endpoint", and `routers/messageRouter.ts` only ever passes a
  /// server-derived `attachmentPath`. The absolute-path door is this server's own addition,
  /// so the shape a shipped client actually sends — the path `POST /attachment/upload`
  /// answered with — is exactly the shape that still works.
  ///
  /// Symlinks are resolved on BOTH sides before the comparison, and that is not a detail: a
  /// prefix test against an unresolved path is defeated by `uploads/x/../../../etc/passwd`,
  /// and on macOS the store itself may sit under `/var`, which IS a symlink to `/private/var`,
  /// so resolving only the input would refuse every legitimate path instead.
  ///
  /// - Parameter extraRoots: Other directories a path may legitimately be under. The send
  ///   path passes Messages' own outgoing staging directory, because a file already inside
  ///   the container is returned untouched by `AttachmentStaging.stage` and can arrive here
  ///   on a second pass.
  public func confined(_ given: String, extraRoots: [String] = []) throws -> String {
    let resolved = Self.canonical(given)
    let roots = ([directory.path] + extraRoots).map { Self.canonical($0) + "/" }
    guard roots.contains(where: { resolved.hasPrefix($0) }) else {
      // Names the rule rather than the path, so the refusal says nothing about what is or is
      // not on this disk.
      throw UploadError.pathNotPermitted
    }
    return resolved
  }

  /// Absolute, symlinks resolved, `.` and `..` collapsed. Purely lexical where the path does
  /// not exist, which is the case a traversal attempt arrives in.
  public static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  // MARK: - Reclaiming

  /// How long an upload is kept.
  ///
  /// Generous, because the path is handed to the CLIENT and the send is a separate call: an
  /// upload-then-send can be minutes apart, and a client that stages an attachment and then
  /// asks the user to confirm can be longer. A day is far past any of that and still bounded.
  ///
  /// Longer than `AttachmentStaging.maximumAge` (one hour) on purpose. That directory holds
  /// copies made FOR a send that has already been issued, so nothing refers to them once the
  /// transfer finishes; these are files a client still holds a path to.
  static let maximumAge: TimeInterval = 24 * 60 * 60

  /// The ceiling, whatever the ages. Oldest evicted first, matching the conversion cache.
  static let sizeBudget = 2 * 1024 * 1024 * 1024

  /// The most ONE chunked transfer may accumulate.
  ///
  /// **The chunked route had no size bound of any kind.** `index < total` is the only check
  /// it makes and `total` is a number the client picked, so a caller could declare a billion
  /// chunks and append until the disk was full: the per-request ceiling
  /// (`HTTPAPIConfiguration.maximumBodySize`, 100 MB) bounds one request, and nothing bounded
  /// the file they all land in.
  ///
  /// A gigabyte, chosen to be unreachable by accident rather than to be tight. The whole-file
  /// route refuses anything over 100 MB (`maximumBodySize`), so ten times that is far past any
  /// attachment a client has reason to send, and it is half of `sizeBudget` — the most a
  /// single file may be and still leave the directory budget meaning something.
  ///
  /// Deliberately generous, because rule 1 outranks this: a ceiling a real client could hit
  /// would be a v1 break, and no shipped client sends anything near it.
  public static let defaultMaximumTransferBytes = 1024 * 1024 * 1024

  /// Bytes that may land between sweeps before one is forced regardless of the interval.
  ///
  /// The interval gate bounds how OFTEN the directory is reclaimed, which bounds nothing about
  /// how much arrives in between — and an hour is a long time at line rate. `maximumTransferBytes`
  /// caps one file; this is what caps the DIRECTORY, because transfer ids are unbounded and
  /// a capped file repeated ten thousand times is the same disk.
  ///
  /// Comfortably above a single ordinary upload, so the common case still sweeps on the clock
  /// and a photo does not pay for a directory scan.
  public static let defaultSweepByteTrigger = 256 * 1024 * 1024

  /// Sweeps if the gate is open, without making the caller wait.
  ///
  /// **Nothing reclaimed this directory before.** Every attachment any client had ever
  /// uploaded stayed under `Application Support/bluebubbles-server/uploads` for the life of
  /// the install: not after the send, not at startup, not on a budget. A chunked transfer
  /// that died partway left its fragment there too. Both sibling stores already had a sweep
  /// — `AttachmentStaging.sweep()` on age, `AttachmentConversion` on age and a budget — and
  /// the one holding the user's own outgoing media, in the clear, had neither.
  ///
  /// Called after a write rather than on a timer, so a server nobody is uploading to does no
  /// work, and the directory only grows when something is written, which is exactly when the
  /// budget can be exceeded. The first attempt after launch always passes the gate, so a
  /// server that starts with a full directory sweeps on its first upload.
  ///
  /// - Parameter wrote: how many bytes this call added, which is the second of the two
  ///   reasons to sweep. See `defaultSweepByteTrigger`: a chunked transfer appends without the
  ///   interval gate ever opening, so time alone is not a bound on what lands here.
  private func sweepIfDue(wrote bytes: Int) {
    let directory = directory
    let logger = logger
    let gate = sweepGate
    let volume = sweepVolume
    // Detached from the request: nothing sending an attachment should wait on a scan.
    Task {
      // Volume FIRST, and the order matters: `attempt()` consumes the interval gate, so
      // asking it when the byte trigger has already fired would spend the hourly sweep on
      // a pass that was going to happen anyway.
      var due = await volume.record(bytes)
      if !due, case .allowed = await gate.attempt() { due = true }
      guard due else { return }
      await volume.reset()
      Self.sweep(in: directory, logger: logger)
    }
  }

  /// Drops uploads past `maximumAge`, then oldest-first until the total is inside the budget.
  ///
  /// Handles files and directories alike: `write` and `append` put a file straight in the
  /// root, `stage` puts one inside a directory of its own, and a sweep that understood only
  /// one of those would leave the other to grow.
  ///
  /// Failures are ignored, as they are in `AttachmentStaging.sweep`: a sweep that cannot run
  /// is untidy, and refusing an upload because of it would be worse.
  static func sweep(
    in directory: URL,
    logger: Logger = Logger(label: "bluebubbles.uploads"),
    maximumAge: TimeInterval = UploadStore.maximumAge,
    sizeBudget: Int = UploadStore.sizeBudget
  ) {
    let manager = FileManager.default
    guard
      let entries = try? manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
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

    for url in entries {
      guard
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate
      else { continue }
      let size = Self.size(of: url)

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
    if total > sizeBudget {
      for entry in kept.sorted(by: { $0.modified < $1.modified }) {
        guard total > sizeBudget else { break }
        guard (try? manager.removeItem(at: entry.url)) != nil else { continue }
        total -= entry.size
        removed += 1
        reclaimed += entry.size
      }
    }

    guard removed > 0 else { return }
    // A count and a size. No file names: they are the names the user gave their own
    // photos, and the redaction rule names file names as content that is never logged.
    logger.info(
      "Reclaimed uploaded attachments",
      metadata: [
        "removed": .stringConvertible(removed),
        "reclaimedMB": .stringConvertible(reclaimed / (1024 * 1024)),
        "remainingMB": .stringConvertible(total / (1024 * 1024)),
      ])
  }

  /// Bytes at a path, following one level into a `stage` directory.
  private static func size(of url: URL) -> Int {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
    if !isDirectory.boolValue {
      return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
    let contents =
      (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]))
      ?? []
    return contents.reduce(0) {
      $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
  }

  /// The directory, created on first use.
  private func prepared() throws -> URL {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  /// Writes a complete file and returns its path.
  ///
  /// The name is made unique by prefixing it, so a path from here is not one to hand to
  /// Messages as-is: the prefix becomes the attachment's name on the recipient's device.
  /// `stage(_:named:)` keeps the name; this is for files a later call renames or reads.
  public func write(_ data: Data, named name: String) throws -> String {
    let url = try prepared().appendingPathComponent(Self.uniqueName(for: name))
    try data.write(to: url, options: [.atomic])
    sweepIfDue(wrote: data.count)
    return url.path
  }

  /// Writes a complete file under EXACTLY the name given, in a directory of its own.
  ///
  /// For a file that is about to be sent: `AttachmentStaging` preserves the last path
  /// component because it becomes the attachment's filename in the conversation, and the
  /// reference (`FileSystem.copyAttachment(path, name)`) names the copy after the client's
  /// `name` field for the same reason. Uniqueness moves to the directory so two uploads of
  /// `IMG_0001.jpg` do not collide and neither is renamed.
  public func stage(_ data: Data, named name: String) throws -> String {
    let base = (name as NSString).lastPathComponent
    let sanitised = String(base.map { $0 == "/" || $0 == ":" ? "-" : $0 })
    let directory = try prepared().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let url = directory.appendingPathComponent(sanitised.isEmpty ? "attachment" : sanitised)
    try data.write(to: url, options: [.atomic])
    sweepIfDue(wrote: data.count)
    return url.path
  }

  /// Appends one chunk of a transfer and returns the file's path.
  ///
  /// Chunk 0 TRUNCATES. A client that retries a failed transfer with the same id would
  /// otherwise append to the previous attempt's bytes and produce a file that is the right
  /// name, the wrong length, and corrupt in a way nothing detects until it is opened.
  ///
  /// A later chunk arriving before chunk 0 is refused rather than reordered: reassembling
  /// out-of-order chunks would need the whole transfer held in memory, which is what this
  /// route exists to avoid, and a client that skipped one has a bug worth surfacing.
  ///
  /// A transfer past `maximumTransferBytes` is refused and its partial file DELETED. Deleting
  /// it is the half that matters: leaving it for the sweep means the refusal costs an attacker
  /// nothing, because the bytes they wanted on the disk are on the disk and only the last
  /// request failed.
  public func append(
    _ chunk: Data,
    to transferID: String,
    named name: String,
    expectingChunk index: Int
  ) throws -> String {
    let url = try prepared().appendingPathComponent(
      "\(Self.safeIdentifier(transferID)).\((name as NSString).pathExtension)"
    )

    if index == 0 {
      guard chunk.count <= maximumTransferBytes else {
        throw UploadError.transferTooLarge(limit: maximumTransferBytes)
      }
      try chunk.write(to: url, options: [.atomic])
      sweepIfDue(wrote: chunk.count)
      return url.path
    }

    // One `stat` answering both questions. The existence check that used to stand here
    // answered only the first, and the second had no answer at all.
    guard let existing = Self.fileSize(at: url) else {
      throw UploadError.chunkOutOfOrder(index: index, transferID: transferID)
    }
    guard existing + chunk.count <= maximumTransferBytes else {
      try? FileManager.default.removeItem(at: url)
      throw UploadError.transferTooLarge(limit: maximumTransferBytes)
    }

    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: chunk)
    // Every chunk, not just chunk 0. Sweeping only at the start of a transfer is what let an
    // hour of appends run unreclaimed; the byte trigger is what makes this cheap, since the
    // interval gate stays shut for all of them.
    //
    // Safe to run against a transfer in flight: the budget pass evicts oldest-first by
    // modification time, and a file being appended to right now is the newest thing here.
    sweepIfDue(wrote: chunk.count)
    return url.path
  }

  /// A plain file's size, or nil when there is no file. `resourceValues` throws for a missing
  /// path, which is the "no chunk 0 yet" answer rather than an error.
  private static func fileSize(at url: URL) -> Int? {
    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
  }

  /// A transfer id as a path component.
  ///
  /// The id comes from a client and lands in a path. Anything that is not a plain identifier
  /// is replaced, so `../../` cannot escape the directory.
  static func safeIdentifier(_ transferID: String) -> String {
    String(transferID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
  }

  /// A name that cannot collide and cannot escape the directory.
  static func uniqueName(for name: String) -> String {
    let base = (name as NSString).lastPathComponent
    let sanitised = base.map { $0 == "/" || $0 == ":" ? "-" : $0 }
    return "\(UUID().uuidString)-\(String(sanitised))"
  }
}

/// Bytes written since the last sweep.
///
/// Separate from `IntervalGate` rather than a field on it: that gate is shared with the FindMy
/// refresh and the conversion cache, and "how many bytes" is not a concept either of those has.
/// An actor for the same reason `IntervalGate` is one — `UploadStore` is a `Sendable` struct
/// built once and shared, so its mutable state has to live somewhere that can be mutated
/// through a `let`.
actor SweepVolume {

  private let trigger: Int
  private var pending = 0

  init(trigger: Int) {
    self.trigger = trigger
  }

  /// Adds `bytes` and reports whether that is now enough to sweep on.
  ///
  /// Does NOT reset on its own: the caller resets once the sweep has actually been started,
  /// so a decision that is then discarded does not throw the count away with it.
  func record(_ bytes: Int) -> Bool {
    pending += max(0, bytes)
    return pending >= trigger
  }

  func reset() {
    pending = 0
  }
}
