//  AttachmentStaging
//  Puts an outgoing attachment somewhere Messages.app is allowed to read it.

import BBPrivateAPIContract
import Foundation

/// Copies outgoing attachments into Messages' container before the helper is asked to send
/// them.
///
/// **Messages is sandboxed and cannot read files outside its own container.** The helper runs
/// inside Messages, so it inherits that restriction — and so does ChatKit, which is what
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
/// nothing. The send then names a transfer with no bytes behind it, and imagent — correctly —
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
  /// A file already inside the container is returned untouched — re-copying it would be
  /// pure cost, and the upload endpoints already write there.
  public static func stage(_ path: String) throws -> String {
    let manager = FileManager.default
    guard manager.fileExists(atPath: path) else {
      throw PrivateAPIError.rejectedByMessages(reason: "no file at \(path)")
    }
    if path.hasPrefix(SocketLocation.messagesContainer + "/") { return path }

    sweep()
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
        text: part.text, attachmentPath: try stage(path), mention: part.mention
      )
    }
  }

  /// Removes staged copies older than `maximumAge`.
  ///
  /// Failures are ignored on purpose: a sweep that cannot run is untidy, and refusing to
  /// send an attachment because of it would be worse.
  public static func sweep() {
    let manager = FileManager.default
    guard let entries = try? manager.contentsOfDirectory(atPath: root) else { return }
    let cutoff = Date().addingTimeInterval(-maximumAge)
    for entry in entries {
      let directory = root + "/" + entry
      let created = (try? manager.attributesOfItem(atPath: directory))?[.creationDate]
      guard let created = created as? Date, created < cutoff else { continue }
      try? manager.removeItem(atPath: directory)
    }
  }
}
