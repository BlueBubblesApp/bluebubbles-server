//  AttachmentInterface
//  Attachment metadata, bytes, and the derived forms clients ask for.

import BBCore
import BBIMessage
import BBMedia
import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation
import Logging

/// A fetch from iCloud that did not finish inside its wait. The reference's sentence, in
/// the slot its unhandled `Error` puts it: a 500 `Server Error`.
public struct AttachmentDownloadIncomplete: BBError, Equatable {
  public let transferState: Int
  public var code: String { "attachment.download_incomplete" }
  public var domain: String { "Attachments" }
  public var title: String { "The attachment did not finish downloading" }
  public var body: String { "Failed to download attachment! Transfer State: \(transferState)" }
}

public struct AttachmentInterface: MessagesBackedInterface {

  private let repository: MessageRepository
  /// The roles this interface calls, and no more.
  public typealias Helper = any AttachmentAccess

  let privateAPI: Helper?
  let logger: Logger
  private let waits: UnpurgeWaits

  /// How long a fetch from iCloud is waited for, and how often chat.db is asked about it.
  /// A value so a test can run the wait in milliseconds rather than minutes.
  public struct UnpurgeWaits: Sendable {
    /// `forceDownload`: the reference's `maxWaitMs`, ten minutes.
    public var forceDownload: Duration
    /// The ordinary download route, which started a fetch nobody asked to sit on.
    public var downloadRoute: Duration
    /// The reference's `initialWaitMs`, and its interval after.
    public var interval: Duration

    public static let standard = UnpurgeWaits(
      forceDownload: .seconds(600), downloadRoute: .seconds(20), interval: .seconds(5))

    public init(forceDownload: Duration, downloadRoute: Duration, interval: Duration) {
      self.forceDownload = forceDownload
      self.downloadRoute = downloadRoute
      self.interval = interval
    }
  }

  public init(
    repository: MessageRepository,
    privateAPI: Helper? = nil,
    logger: Logger = Logger(label: "bluebubbles.interface.attachment"),
    unpurgeWaits: UnpurgeWaits = .standard
  ) {
    self.repository = repository
    self.privateAPI = privateAPI
    self.logger = logger
    self.waits = unpurgeWaits
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
    AttachmentSerializer.serialize(
      row, metadata: await metadataReader.metadata(for: row),
      hasLivePhoto: await metadataReader.hasLivePhoto(for: row))
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
    guard privateAPI != nil else {
      throw InterfaceError.notFound(
        "attachment \(guid) has been offloaded to iCloud; downloading it needs the "
          + "Private API"
      )
    }
    // A short wait, unlike `forceDownload`: this is the ordinary download route, which a
    // client did not ask to sit on a fetch from iCloud. A fetch that is not done by then
    // carries on, and the next request finds the file.
    guard let fetched = try await unpurge(guid: guid, within: waits.downloadRoute) else {
      throw InterfaceError.notFound(
        "attachment \(guid) is being downloaded from iCloud; ask again shortly")
    }
    return fetched
  }

  /// Pulls an attachment back from iCloud whether or not a copy is on disk.
  ///
  /// What `resolvePath` falls back to, asked for outright: a client that knows the local
  /// copy is stale or truncated has no other way to make Messages fetch it again. Waits as
  /// the reference's `AttachmentInterface.forceDownload` does: up to ten minutes for the
  /// transfer to finish, then the file.
  public func forceDownload(guid: String) async throws -> String {
    _ = try requirePrivateAPI(for: "downloading a purged attachment")
    if let fetched = try await unpurge(guid: guid, within: waits.forceDownload) {
      return fetched
    }
    let state = try await repository.attachment(guid: guid)?.transferState ?? 0
    throw AttachmentDownloadIncomplete(transferState: state)
  }

  /// Asks Messages to fetch a purged attachment, and waits for the bytes.
  ///
  /// The helper answers as soon as Messages ACCEPTS the transfer, with whatever `localPath`
  /// the transfer has at that moment: the finished file for one already here, and often the
  /// empty string for one just started. That empty string was returned as the path, passed
  /// every check (it is a string) and was served as a file. So the answer is only trusted when
  /// it names a file that exists, and otherwise chat.db is watched, as the reference does,
  /// until the row says the transfer finished (`transfer_state` 5) and its file is there.
  ///
  /// Nil when `limit` passes first.
  private func unpurge(guid: String, within limit: Duration) async throws -> String? {
    let api = try requirePrivateAPI(for: "downloading a purged attachment")
    let reported = try await throughMessages { try await api.downloadPurgedAttachment(guid: guid) }
    if !reported.isEmpty, FileManager.default.fileExists(atPath: reported) { return reported }
    return try await poll(.every(waits.interval), within: limit) { [repository] _ in
      guard let row = try await repository.attachment(guid: guid),
        row.transferState == Self.transferFinished, let stored = row.filename
      else { return nil }
      let path = (stored as NSString).expandingTildeInPath
      return FileManager.default.fileExists(atPath: path) ? path : nil
    }
  }

  /// `transfer_state` for a transfer whose bytes are on disk.
  static let transferFinished = 5

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
    // A 404 with the reference's sentence (`attachmentRouter.ts`: `throw new NotFound({
    // error: "Attachment is not an image!" })`). It was a 400 with a sentence of ours, which
    // a client branching on the status reads as its own request being malformed.
    guard FileTypes.isImage(path) else {
      throw InterfaceError.notFound(ReferenceMessages.attachmentNotAnImage)
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
      throw InterfaceError.invalidRequest(
        "attachment \(guid) could not be hashed: \(DiagnosticText.sentence(for: error))")
    }
  }
}

// MARK: - Media totals

extension AttachmentInterface {

  /// The three categories the wire names, in the reference's spelling.
  ///
  /// `audio`, `other` and a computed `total` were being returned as well. They are not in
  /// the reference's response and an added key fails the parity diff exactly as a missing
  /// one does: `getMediaTotals` builds its result from three `if` branches and has no
  /// fourth, so `other` is unreachable there even though its own default `only` list names
  /// it. That quirk is reproduced rather than tidied.
  private static let mediaCategories: [(singular: String, wire: String)] = [
    ("image", "images"), ("video", "videos"), ("location", "locations"),
  ]

  /// Every requested bucket is present, including the zeroes.
  ///
  /// A client rendering three rows should not have to distinguish "no videos" from "the
  /// server forgot to mention videos", and an omitted key reads as the latter.
  public static func serializeMediaTotals(_ counts: [String: Int], only: Set<String>?) -> JSONValue
  {
    var object: [String: JSONValue] = [:]
    for category in mediaCategories where only?.contains(category.singular) ?? true {
      object[category.wire] = .int(counts[category.singular] ?? 0)
    }
    return .object(object)
  }

  /// `server/statistics/media/chat`'s `data`: one entry per chat with any media, each with
  /// its own totals under the same `only` filter.
  public static func serializeMediaTotals(
    byChat rows: [(guid: String, displayName: String?, counts: [String: Int])],
    only: Set<String>?
  ) -> JSONValue {
    .array(
      rows.map { row in
        .object([
          "chatGuid": .string(row.guid),
          "groupName": row.displayName.map(JSONValue.string) ?? .null,
          "totals": serializeMediaTotals(row.counts, only: only),
        ])
      })
  }
}
