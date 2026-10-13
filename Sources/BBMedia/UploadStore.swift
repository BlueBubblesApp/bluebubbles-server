//  UploadStore
//  Where uploads land before they are sent.
//
//  Both upload routes (whole-file multipart and the chunked transfer) write bytes here and
//  hand back a path. Sending is a separate call, which keeps a large file out of the
//  send timeout and lets a client retry the send without re-uploading. The group-icon route
//  writes here too, so an image can be handed to Messages by path.
//
//  In the interfaces layer rather than the handlers because the rules below are decisions, not
//  parsing: where private bytes in transit may live, how a client-chosen transfer id becomes a
//  filename, and what makes a chunked transfer whole.

import BBCore
import Foundation
import Logging

public struct UploadStore: Sendable {

  /// Under the server's own support directory, not the system temporary one: these are the
  /// user's private messages in transit, and a world-readable `/tmp` is the wrong place for
  /// them. Created with owner-only permissions for the same reason.
  public static var defaultDirectory: URL { ApplicationSupport.uploads }

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
  ///
  /// A RELATIVE path is resolved against this store, not the working directory: it is the
  /// form `POST /attachment/upload` hands out (`clientPath(of:)`), and the same confinement
  /// then applies to what it resolves to, so `../` out of the store is refused like any other
  /// path outside it.
  public func confined(_ given: String, extraRoots: [String] = []) throws -> String {
    let absolute = given.hasPrefix("/") ? given : directory.appendingPathComponent(given).path
    let resolved = Self.canonical(absolute)
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
  /// chunks and keep sending until the disk was full: the per-request ceiling
  /// (`HTTPAPIConfiguration.maximumBodySize`, 100 MB) bounds one request, and nothing bounded
  /// the transfer they all belong to.
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
  ///   reasons to sweep. See `defaultSweepByteTrigger`: a chunked transfer keeps writing
  ///   without the interval gate ever opening, so time alone is not a bound on what lands here.
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
  /// Handles files and directories alike: `write` puts a file straight in the root, `stage`
  /// and `storeChunk` put theirs inside a directory of their own, and a sweep that understood
  /// only one of those would leave the other to grow.
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

  /// Bytes at a path, following one level into a `stage` or chunk directory.
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

  /// Writes a complete file under the name given, in a directory of its own.
  ///
  /// The name as `AttachmentFilename.sanitised` leaves it, which for an ordinary filename is
  /// the name unchanged.
  ///
  /// For a file that is about to be sent: `AttachmentStaging` preserves the last path
  /// component because it becomes the attachment's filename in the conversation, and the
  /// reference (`FileSystem.copyAttachment(path, name)`) names the copy after the client's
  /// `name` field for the same reason. Uniqueness moves to the directory so two uploads of
  /// `IMG_0001.jpg` do not collide and neither is renamed.
  ///
  /// The directory is a LOWERCASE UUID because it reaches the wire: `POST /attachment/upload`
  /// answers with `<uuid>/<file>` (`clientPath(of:)`), and the reference's is `uuidv4()`
  /// (`fileSystem/index.ts:211`), which is lowercase.
  public func stage(_ data: Data, named name: String) throws -> String {
    let url = try freshDirectory().appendingPathComponent(AttachmentFilename.sanitised(name))
    try data.write(to: url, options: [.atomic])
    sweepIfDue(wrote: data.count)
    return url.path
  }

  /// The file at `path` under the name a SEND gave it, which outranks the one it was uploaded
  /// under.
  ///
  /// The reference does this on every send that names a file: multipart copies each part to
  /// `part.name` (`messageInterface.ts:585-592`), and the attachment route writes under the
  /// form's `name`. The upload's own filename is only the default, because it is whatever
  /// the client's HTTP library or file picker produced, where `name` is the field a client
  /// fills in on purpose. It also lets one upload be sent twice under two names.
  ///
  /// A HARD LINK in a fresh directory rather than a copy: the source is already in this
  /// store, so this costs a directory entry instead of a second copy of a video, and the
  /// original keeps its name for any other send that refers to it. A copy only where linking
  /// is refused (a source in `extraRoots` on another volume). The sweep counts a linked file
  /// twice against the budget, which can only make it reclaim sooner.
  ///
  /// - Parameter path: a path `confined(_:extraRoots:)` already returned. This does not
  ///   confine; it is called on the far side of that check.
  /// - Returns: `path` itself when the name is already the one it has.
  public func renamed(_ path: String, to name: String) throws -> String {
    let current = (path as NSString).lastPathComponent
    let wanted = AttachmentFilename.sanitised(name, fallback: current)
    guard wanted != current else { return path }

    let destination = try freshDirectory().appendingPathComponent(wanted)
    let source = URL(fileURLWithPath: path)
    do {
      try FileManager.default.linkItem(at: source, to: destination)
    } catch {
      try FileManager.default.copyItem(at: source, to: destination)
    }
    return destination.path
  }

  /// A new owner-only directory for one file, named by a LOWERCASE UUID (see `stage`).
  private func freshDirectory() throws -> URL {
    let directory = try prepared().appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  /// The path a client is handed for a file `stage(_:named:)` wrote: `<uuid>/<file>`,
  /// relative to this store.
  ///
  /// The reference's form (`attachmentRouter.ts:189-194` keeps the last two components of
  /// the copy it made), so a client that stores or displays it sees the same shape from
  /// either server. `confined(_:extraRoots:)` resolves it back against this directory.
  public func clientPath(of staged: String) -> String {
    let root = directory.path + "/"
    return staged.hasPrefix(root) ? String(staged.dropFirst(root.count)) : staged
  }

  // MARK: - Chunked transfers
  //
  // The reference's model (`FileSystem.saveAttachmentChunk`, `fileSystem/index.ts:289-293`):
  // each chunk is its own file named by its index, in a directory named by the transfer, and
  // nothing is joined until the request carrying `isComplete`. So chunks may arrive in ANY
  // order, a retried chunk replaces the one it retries, and the final request is the only one
  // that can find the transfer incomplete.
  //
  // This replaced a single file appended to in order, which refused a chunk that arrived
  // before chunk 0 and joined nothing else out of order. That was never the reference's
  // contract, and a client uploading slices in parallel would have been refused.

  /// Stores one chunk of a transfer under its index, replacing any earlier copy of it.
  ///
  /// A transfer past `maximumTransferBytes` is refused and its chunks DELETED. Deleting them
  /// is the half that matters: leaving them for the sweep means the refusal costs an attacker
  /// nothing, because the bytes they wanted on the disk are on the disk and only the last
  /// request failed. Counted across every chunk held, because `totalChunks` is a number the
  /// client picked and the per-request ceiling (`HTTPAPIConfiguration.maximumBodySize`) bounds
  /// one chunk, not the transfer.
  public func storeChunk(_ chunk: Data, transfer transferID: String, index: Int) throws {
    let directory = try chunkDirectory(for: transferID)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let url = directory.appendingPathComponent("\(index).chunk")

    // The chunk this one replaces does not count against it: a retry is not growth. By name,
    // because a listed URL and a built one can spell the same file differently (`/private`).
    let held = Self.chunkFiles(in: directory)
      .filter { $0.lastPathComponent != url.lastPathComponent }
      .reduce(0) { $0 + (Self.fileSize(at: $1) ?? 0) }
    guard held + chunk.count <= maximumTransferBytes else {
      try? FileManager.default.removeItem(at: directory)
      throw UploadError.transferTooLarge(limit: maximumTransferBytes)
    }

    try chunk.write(to: url, options: [.atomic])
    // Every chunk. The byte trigger is what makes this cheap, since the interval gate stays
    // shut for all of them. Safe against a transfer in flight: the budget pass evicts
    // oldest-first by modification time, and a directory being written to right now is the
    // newest thing here.
    sweepIfDue(wrote: chunk.count)
  }

  /// Joins a transfer's chunks in index order into one file named `name`, and returns its path.
  ///
  /// The chunks are LEFT where they are. The reference deletes them only after the send
  /// succeeds (`FileSystem.deleteChunks`, called after `sendAttachmentSync` returns), so a
  /// final request whose send fails can be retried and finds the transfer whole. Call
  /// `discardChunks(transfer:)` once the send has worked.
  ///
  /// Streamed, a chunk at a time: the point of a chunked upload is a file too large to buffer.
  ///
  /// - Throws: `UploadError.missingChunks` when the count held is not `total`, as the
  ///   reference refuses (`messageRouter.ts:538-541`). Indices are validated as `< total`
  ///   before a chunk is stored, so `total` chunks held means exactly 0..<total.
  public func assembleChunks(
    transfer transferID: String, expecting total: Int, named name: String
  ) throws -> String {
    let directory = try chunkDirectory(for: transferID)
    let chunks = Self.chunkFiles(in: directory)
      .compactMap { url in Self.chunkIndex(of: url).map { (index: $0, url: url) } }
      .sorted { $0.index < $1.index }
    guard chunks.count == total else {
      throw UploadError.missingChunks(expected: total, found: chunks.count)
    }

    let url = try freshDirectory().appendingPathComponent(AttachmentFilename.sanitised(name))
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    let output = try FileHandle(forWritingTo: url)
    defer { try? output.close() }
    for chunk in chunks {
      try output.write(contentsOf: try Data(contentsOf: chunk.url))
    }
    return url.path
  }

  /// Drops a transfer's chunks, once the file they made has been sent.
  public func discardChunks(transfer transferID: String) {
    guard let directory = try? chunkDirectory(for: transferID) else { return }
    try? FileManager.default.removeItem(at: directory)
  }

  /// One directory per transfer, directly under the store so the sweep sees it as one entry
  /// and sizes it (`size(of:)` follows exactly one level). Prefixed so it can never be taken
  /// for a `stage` directory, which is a bare UUID.
  private func chunkDirectory(for transferID: String) throws -> URL {
    try prepared().appendingPathComponent("chunks-\(Self.safeIdentifier(transferID))")
  }

  private static func chunkFiles(in directory: URL) -> [URL] {
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    return contents.filter { $0.pathExtension == "chunk" }
  }

  private static func chunkIndex(of url: URL) -> Int? {
    Int(url.deletingPathExtension().lastPathComponent)
  }

  /// A plain file's size, or nil when there is no file.
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
    "\(UUID().uuidString)-\(AttachmentFilename.sanitised(name))"
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
