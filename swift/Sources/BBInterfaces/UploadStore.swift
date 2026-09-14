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
  private let logger: Logger

  public init(
    directory: URL = UploadStore.defaultDirectory,
    sweepInterval: Duration = .seconds(3600),
    logger: Logger = Logger(label: "bluebubbles.uploads")
  ) {
    self.directory = directory
    self.sweepGate = IntervalGate(interval: sweepInterval)
    self.logger = logger
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
  private func sweepIfDue() {
    let directory = directory
    let logger = logger
    let gate = sweepGate
    // Detached from the request: nothing sending an attachment should wait on a scan.
    Task {
      guard case .allowed = await gate.attempt() else { return }
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
    sweepIfDue()
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
    sweepIfDue()
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
      try chunk.write(to: url, options: [.atomic])
      // Chunk 0 only. A later chunk extends a file the sweep would have to be careful
      // around anyway, and the gate would refuse it; sweeping when a transfer STARTS is
      // what makes room for it.
      sweepIfDue()
      return url.path
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
      throw InterfaceError.invalidRequest(
        "chunk \(index) arrived before chunk 0 for transfer \(transferID)"
      )
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: chunk)
    return url.path
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

/// Where Messages keeps group photos.
///
/// Messages stores these under its own support directory keyed by the chat's group id, not in
/// the attachments tree, and with no row in chat.db. A chat with no `group_id` has never had a
/// photo set.
public enum GroupIconStore {

  public static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Messages/Attachments/GroupPhotoImage")
  }

  /// The group photo for a chat, if one is set.
  public static func path(
    forGroupID groupID: String?, in directory: URL = defaultDirectory
  ) -> String? {
    guard let groupID, !groupID.isEmpty else { return nil }
    for candidate in ["\(groupID)", "\(groupID).jpeg", "\(groupID).png", "\(groupID).heic"] {
      let path = directory.appendingPathComponent(candidate).path
      if FileManager.default.fileExists(atPath: path) { return path }
    }
    return nil
  }
}
