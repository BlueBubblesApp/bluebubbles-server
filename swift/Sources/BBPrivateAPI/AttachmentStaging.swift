//  AttachmentStaging
//  Puts an outgoing attachment somewhere Messages.app is allowed to read it.

import BBPrivateAPIContract
import Foundation

/// Copies outgoing attachments into Messages' container before the helper is asked to send
/// them.
///
/// **Messages is sandboxed and cannot read files outside its own container.** The helper runs
/// inside Messages, so it inherits that restriction, and so does ChatKit, which is what
/// actually opens the file. This was measured rather than assumed, and the way it fails is
/// the reason it is worth a file of its own:
///
///     source: ~/Documents/profile-pic.jpg
///     transfer created, GUID issued, localPath assigned
///     existsAtLocalPath = 0   totalBytes = 0   isFileURLFinalized = 0
///     message sent, no error, cache_has_attachments = 0, no attachment row
///
/// `mediaObjectWithFileURL:filename:transcoderUserInfo:` allocates the transfer and computes
/// where the bytes belong, and when the sandbox denies the read it copies nothing and reports
/// nothing. The send then names a transfer with no bytes behind it, and imagent, correctly,
/// attaches nothing. Every layer succeeds and the attachment silently disappears.
///
/// The server is the right place to fix it: it has Full Disk Access (it needs it for chat.db
/// and for the socket, which lives in the same container), and the helper does not. Copying
/// here turns the helper's read into a container-to-container one, which the sandbox permits.
///
/// Staged copies are swept by age rather than deleted after each send. The daemon may still
/// be reading the file when the send call returns, and a sweep costs nothing next to the
/// chance of pulling bytes out from under an in-flight transfer.
public enum AttachmentStaging {

  /// Long enough that no in-flight transfer is still reading, short enough that a crashed
  /// server does not leave a copy of someone's photos around indefinitely.
  static let maximumAge: TimeInterval = 60 * 60

  static var root: String {
    SocketLocation.messagesContainer + "/tmp/BlueBubbles/Outgoing"
  }

  /// Returns a path inside Messages' container holding the same bytes as `path`.
  ///
  /// A file already inside the container is returned untouched: re-copying it would be
  /// pure cost, and the upload endpoints already write there.
  public static func stage(_ path: String) throws -> String {
    let manager = FileManager.default
    guard manager.fileExists(atPath: path) else {
      throw PrivateAPIError.rejectedByMessages(reason: "no file at \(path)")
    }
    if path.hasPrefix(SocketLocation.messagesContainer + "/") { return path }

    sweepIfDue()
    // The filename is preserved because it becomes the attachment's name in the
    // conversation; only the directory is made unique.
    let directory = root + "/" + UUID().uuidString
    let destination = directory + "/" + URL(fileURLWithPath: path).lastPathComponent
    do {
      try manager.createDirectory(
        atPath: directory, withIntermediateDirectories: true
      )
      try manager.copyItem(atPath: path, toPath: destination)
    } catch {
      throw PrivateAPIError.rejectedByMessages(
        reason:
          "could not stage \(path) for Messages to read: \(error.localizedDescription)"
      )
    }
    return destination
  }

  /// Stages every attachment part, leaving text parts alone.
  public static func stage(parts: [MessagePart]) throws -> [MessagePart] {
    try parts.map { part in
      guard let path = part.attachmentPath else { return part }
      return MessagePart(
        text: part.text, attachmentPath: try stage(path), mention: part.mention,
        formatting: part.formatting
      )
    }
  }

  /// How much staged output may sit in the container regardless of age.
  ///
  /// An age cutoff alone is the omission `.claude/docs/performance.md` names as the one that
  /// gets missed: a burst of large sends inside one hour is bounded by nothing. Staging is
  /// the store most likely to hold a few very large files, because what lands here is
  /// whatever someone is sending -- a video, at whatever size their phone recorded it.
  static let sizeBudget: Int64 = 512 * 1024 * 1024

  /// At most one sweep every five minutes, however many sends happen in between.
  ///
  /// This ran on EVERY send: a full directory enumeration, plus an attribute dictionary per
  /// entry, to answer a question that changes on the scale of the age cutoff. Both sibling
  /// stores already gate their sweeps; this one did not.
  ///
  /// A plain lock rather than `IntervalGate`, which is an actor: `stage` is synchronous and
  /// called from a synchronous send path, so there is nowhere to await from.
  private static let sweepInterval: TimeInterval = 300
  private static let sweepLock = NSLock()
  nonisolated(unsafe) private static var lastSweep: Date?

  /// Runs a sweep if one has not run recently.
  static func sweepIfDue(now: Date = Date()) {
    let isDue = sweepLock.withLock {
      if let last = lastSweep, now.timeIntervalSince(last) < sweepInterval { return false }
      lastSweep = now
      return true
    }
    guard isDue else { return }
    sweep(now: now)
  }

  /// Removes staged copies older than `maximumAge`, then the oldest remaining until the
  /// directory is inside `sizeBudget`.
  ///
  /// Failures are ignored on purpose: a sweep that cannot run is untidy, and refusing to
  /// send an attachment because of it would be worse.
  public static func sweep(now: Date = Date()) {
    let manager = FileManager.default
    guard let entries = try? manager.contentsOfDirectory(atPath: root) else { return }
    let cutoff = now.addingTimeInterval(-maximumAge)

    /// One `stat` per entry rather than an attribute dictionary; see
    /// `AttachmentConversion.modificationTime`.
    func created(_ path: String) -> Date? {
      var status = stat()
      guard stat(path, &status) == 0 else { return nil }
      return Date(timeIntervalSince1970: Double(status.st_birthtimespec.tv_sec))
    }

    var surviving: [(path: String, created: Date, bytes: Int64)] = []
    for entry in entries {
      let directory = root + "/" + entry
      guard let created = created(directory) else { continue }
      if created < cutoff {
        try? manager.removeItem(atPath: directory)
        continue
      }
      surviving.append((directory, created, size(of: directory)))
    }

    // Oldest first out, which is the same order the age cutoff uses: a staged copy's value
    // only decreases with time, since the transfer that needed it has either finished or
    // failed.
    var total = surviving.reduce(Int64(0)) { $0 + $1.bytes }
    guard total > sizeBudget else { return }
    for entry in surviving.sorted(by: { $0.created < $1.created }) {
      guard total > sizeBudget else { break }
      try? manager.removeItem(atPath: entry.path)
      total -= entry.bytes
    }
  }

  /// Bytes under a directory, one `stat` per file.
  private static func size(of directory: String) -> Int64 {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(atPath: directory)
    else { return 0 }
    var total: Int64 = 0
    for entry in entries {
      var status = stat()
      guard stat(directory + "/" + entry, &status) == 0 else { continue }
      total += Int64(status.st_size)
    }
    return total
  }
}
