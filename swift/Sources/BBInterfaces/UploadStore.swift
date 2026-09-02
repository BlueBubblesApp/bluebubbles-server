//  UploadStore
//  Where uploads land before they are sent.
//
//  Both upload routes — whole-file multipart and the older base64 chunk stream — write bytes
//  here and hand back a path. Sending is a separate call, which keeps a large file out of the
//  send timeout and lets a client retry the send without re-uploading. The group-icon route
//  writes here too, so an image can be handed to Messages by path.
//
//  In the interfaces layer rather than the handlers because the rules below are decisions, not
//  parsing: where private bytes in transit may live, how a client-chosen transfer id becomes a
//  filename, and what a chunk arriving out of order means.

import Foundation

public struct UploadStore: Sendable {

  /// Under the server's own support directory, not the system temporary one: these are the
  /// user's private messages in transit, and a world-readable `/tmp` is the wrong place for
  /// them. Created with owner-only permissions for the same reason.
  public static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/bluebubbles-server/uploads")
  }

  public let directory: URL

  public init(directory: URL = UploadStore.defaultDirectory) {
    self.directory = directory
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
  public func write(_ data: Data, named name: String) throws -> String {
    let url = try prepared().appendingPathComponent(Self.uniqueName(for: name))
    try data.write(to: url, options: [.atomic])
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
  /// route exists to avoid — and a client that skipped one has a bug worth surfacing.
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
/// Messages stores these under its own support directory keyed by the chat's group id — not in
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
