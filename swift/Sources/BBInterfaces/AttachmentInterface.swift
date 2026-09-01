//  AttachmentInterface
//  Attachment metadata, bytes, and the derived forms clients ask for.

import BBCore
import BBIMessage
import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation
import Logging

public struct AttachmentInterface: MessagesBackedInterface {

  private let repository: MessageRepository
  let privateAPI: (any PrivateAPI)?
  let logger: Logger

  public init(
    repository: MessageRepository,
    privateAPI: (any PrivateAPI)? = nil,
    logger: Logger = Logger(label: "bluebubbles.interface.attachment")
  ) {
    self.repository = repository
    self.privateAPI = privateAPI
    self.logger = logger
  }

  public func count() async throws -> Int {
    try await repository.attachmentCount()
  }

  /// Attachment totals by media category, across the whole database.
  public func mediaCounts() async throws -> [String: Int] {
    try await repository.mediaCounts()
  }

  /// The same totals, one entry per chat that has any media at all.
  ///
  /// An ARRAY, and every chat that has any media — not one object for a requested chat. The
  /// route takes no `chatGuid`, which is what the reference does and what a client calling it
  /// as documented expects.
  public func mediaCountsByChat() async throws -> [(
    guid: String, displayName: String?, counts: [String: Int]
  )] {
    try await repository.mediaCountsByChat()
  }

  /// The ROW, not its wire form. Serialization happens at the edge — see `serialize`.
  ///
  /// Two callers of this wanted exactly two fields and were paying for a full serialization
  /// to read them back out by string key — `metadata?["mimeType"]?.stringValue`. That is
  /// both wasteful and unchecked: a rename inside the serializer would have turned those
  /// into silent nils, and the download would have started guessing content types.
  public func find(guid: String) async throws -> AttachmentRow? {
    try await repository.attachment(guid: guid)
  }

  /// Wire form, for the HTTP layer.
  public func serialize(_ row: AttachmentRow) -> JSONValue {
    AttachmentSerializer.serialize(row)
  }

  /// Resolves an attachment's bytes on disk.
  ///
  /// `filename` in chat.db is stored with a literal `~` for the home directory, which no
  /// file API expands — reading it unexpanded is the classic "attachment not found" for an
  /// attachment that is plainly there.
  ///
  /// A purged attachment (offloaded to iCloud) has a row and a path but no bytes. That is
  /// recoverable through the Private API, and reported distinctly when it is not, because
  /// "not downloaded yet" and "gone" call for different things from a client.
  public func resolvePath(guid: String) async throws -> String {
    guard let row = try await repository.attachment(guid: guid) else {
      throw InterfaceError.notFound("no attachment with GUID \(guid)")
    }
    guard let stored = row.filename else {
      throw InterfaceError.notFound("attachment \(guid) has no file path")
    }
    let path = (stored as NSString).expandingTildeInPath

    if FileManager.default.fileExists(atPath: path) { return path }

    // Present in the database, absent on disk: purged to iCloud.
    guard let privateAPI else {
      throw InterfaceError.notFound(
        "attachment \(guid) has been offloaded to iCloud; downloading it needs the "
          + "Private API"
      )
    }
    return try await throughMessages {
      try await privateAPI.downloadPurgedAttachment(guid: guid)
    }
  }

  public func data(guid: String) async throws -> (data: Data, mimeType: String, name: String) {
    let path = try await resolvePath(guid: guid)
    let row = try await repository.attachment(guid: guid)
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return (
      data,
      row?.mimeType ?? "application/octet-stream",
      row?.transferName ?? (path as NSString).lastPathComponent
    )
  }

  /// A blurhash for an image attachment.
  ///
  /// Clients render this as a placeholder while the real image loads, so it must be cheap
  /// and it must not fail loudly — a missing placeholder is a cosmetic problem, whereas an
  /// error here would break the message list around it.
  public func blurhash(guid: String, components: (x: Int, y: Int) = (4, 3)) async throws -> String {
    let path = try await resolvePath(guid: guid)
    guard FileTypes.isImage(path) else {
      throw InterfaceError.invalidRequest("attachment \(guid) is not an image")
    }
    do {
      return try Blurhash.encode(
        imageAt: path, componentsX: components.x, componentsY: components.y
      )
    } catch {
      throw InterfaceError.invalidRequest("attachment \(guid) could not be hashed: \(error)")
    }
  }
}
