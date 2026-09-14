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
  /// The roles this interface calls, and no more.
  public typealias Helper = any AttachmentAccess

  let privateAPI: Helper?
  let logger: Logger

  public init(
    repository: MessageRepository,
    privateAPI: Helper? = nil,
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
  /// An ARRAY, and every chat that has any media, not one object for a requested chat. The
  /// route takes no `chatGuid`, which is what the reference does and what a client calling it
  /// as documented expects.
  public func mediaCountsByChat() async throws -> [(
    guid: String, displayName: String?, counts: [String: Int]
  )] {
    try await repository.mediaCountsByChat()
  }

  /// The ROW, not its wire form. Serialization happens at the edge; see `serialize`.
  ///
  /// Two callers of this wanted exactly two fields and were paying for a full serialization
  /// to read them back out by string key: `metadata?["mimeType"]?.stringValue`. That is
  /// both wasteful and unchecked: a rename inside the serializer would have turned those
  /// into silent nils, and the download would have started guessing content types.
  public func find(guid: String) async throws -> AttachmentRow? {
    try await repository.attachment(guid: guid)
  }

  /// Attachment dimensions and durations, cached across requests. See
  /// `AttachmentMetadataReader`.
  let metadataReader = AttachmentMetadataReader()

  /// Blurhashes, cached across requests. Same shape and the same reasoning as
  /// `metadataReader`; see `BlurhashCache`.
  let blurhashCache = BlurhashCache()

  /// Wire form, for the HTTP layer.
  ///
  /// Reads the file, because `GET /attachment/:guid` serialises under the reference's
  /// DEFAULT attachment config (whose `loadMetadata` is true) and its recorded response
  /// carries `height`, `width` and `metadata`. Unlike the message routes there is no `with`
  /// to gate it: one attachment, one probe.
  public func serialize(_ row: AttachmentRow) async -> JSONValue {
    AttachmentSerializer.serialize(row, metadata: await metadataReader.metadata(for: row))
  }

  /// Resolves an attachment's bytes on disk.
  ///
  /// `filename` in chat.db is stored with a literal `~` for the home directory, which no
  /// file API expands; reading it unexpanded is the classic "attachment not found" for an
  /// attachment that is plainly there.
  ///
  /// A purged attachment (offloaded to iCloud) has a row and a path but no bytes. That is
  /// recoverable through the Private API, and reported distinctly when it is not, because
  /// "not downloaded yet" and "gone" call for different things from a client.
  public func resolvePath(guid: String) async throws -> String {
    guard let row = try await repository.attachment(guid: guid) else {
      throw InterfaceError.notFound(ReferenceMessages.attachmentNotFound)
    }
    guard let stored = row.filename else {
      throw InterfaceError.notFound(ReferenceMessages.attachmentNotOnDisk)
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

  /// A blurhash for an image attachment.
  ///
  /// Clients render this as a placeholder while the real image loads, so it must be cheap
  /// and it must not fail loudly: a missing placeholder is a cosmetic problem, whereas an
  /// error here would break the message list around it.
  /// - Parameters:
  ///   - components: how many basis functions the hash carries. `(3, 3)` matches the
  ///     reference's default; the count is part of the hash string, so a different default
  ///     is a different answer to the same request.
  ///   - maximumEdge: the caller's `width`/`height`, as an upper bound on the box the image
  ///     is scaled into before hashing. The route accepted both and passed neither, so a
  ///     client asking for a hash of a particular size got one of ours. Clamped to something
  ///     sane at the bottom: a blurhash of a 1×1 thumbnail is a single colour, and a client
  ///     passing `width=0` means "no opinion", not "one pixel".
  public func blurhash(
    guid: String,
    components: (x: Int, y: Int) = (3, 3),
    maximumEdge: Int? = nil
  ) async throws -> String {
    let path = try await resolvePath(guid: guid)
    guard FileTypes.isImage(path) else {
      throw InterfaceError.invalidRequest("attachment \(guid) is not an image")
    }
    let edge = maximumEdge.map { max(16, min($0, 512)) } ?? 64
    // The transform is fast now (a 512-pixel box at 9x9 components went from 438ms to 15ms),
    // so what a repeat request costs is the DECODE: a 12-megapixel HEIC read off disk and
    // scaled, which is tens of milliseconds here and several times that on the hardware this
    // server is often deployed to. A gallery re-opening re-hashed every thumbnail it showed.
    //
    // Safe to cache by GUID because an attachment's bytes do not change once it has
    // transferred -- the same reason `AttachmentMetadataReader` caches what it reads.
    let key = BlurhashCache.Key(
      guid: guid, componentsX: components.x, componentsY: components.y,
      maximumEdge: edge)
    if let cached = await blurhashCache.hash(for: key) { return cached }
    do {
      let hash = try Blurhash.encode(
        imageAt: path, componentsX: components.x, componentsY: components.y,
        downsampleTo: edge
      )
      await blurhashCache.remember(hash, for: key)
      return hash
    } catch {
      throw InterfaceError.invalidRequest("attachment \(guid) could not be hashed: \(error)")
    }
  }
}
