//  MessageInterface
//  Message operations, independent of how they were asked for.
//
//  Controllers stay thin and delegate here, and the same methods serve the HTTP routes, the
//  legacy socket commands, and the SwiftUI app.
//
//  It is also where the send-backend decision lives. `MessageInterface` picks between the
//  Private API and AppleScript per operation and reports capability, rather than failing late
//  with an obscure error — see `.claude/docs/imessage.md`.

import BBAppleScript
import BBIMessage
import BBPrivateAPIContract
import BBSerialization
import Foundation
import Logging

public struct MessageInterface: MessagesBackedInterface {

  let repository: MessageRepository
  /// Not `private`: `MessageSending.swift` and `MessageMutation.swift` are extensions on
  /// this type in other files, and `private` is file-scoped. Still module-internal.
  let serializer: MessageSerializer
  /// The roles this interface calls, and no more.
  ///
  /// `PollControl` and `MessageSending`'s `sendAppMessage` are here because `PollInterface`
  /// and `AppMessageInterface` are extensions on this type and reach the helper through it.
  public typealias Helper = any PrivateAPIConnection & MessageSending & MessageMutation
    & MessageQuerying & ScheduledMessaging & PollControl

  let privateAPI: Helper?
  /// Not `private`: `MessageSending.swift` and `MessageMutation.swift` are extensions on
  /// this type in other files, and `private` is file-scoped. Still module-internal.
  let appleScript: AppleScriptMessageSender
  private let formatter: AddressFormatter
  let logger: Logger

  /// Attachment dimensions and durations, cached across requests. See
  /// `AttachmentMetadataReader` — this is why it is a stored property rather than built per
  /// call: the cache is the point.
  let attachmentMetadata = AttachmentMetadataReader()

  public init(
    repository: MessageRepository,
    serializer: MessageSerializer,
    privateAPI: Helper? = nil,
    appleScript: AppleScriptMessageSender = AppleScriptMessageSender(),
    formatter: AddressFormatter = .shared,
    logger: Logger = Logger(label: "bluebubbles.interface.message")
  ) {
    self.repository = repository
    self.serializer = serializer
    self.privateAPI = privateAPI
    self.appleScript = appleScript
    self.formatter = formatter
    self.logger = logger
  }

  // MARK: - Reading

  public struct Query: Sendable {
    public var chatGUID: String?
    public var limit: Int
    public var offset: Int
    public var ascending: Bool
    public var after: Date?
    public var before: Date?
    /// Which related objects to load. Each costs a query per row, so none are loaded
    /// unless asked for — participants especially, which is where a chat listing spends
    /// most of its time when loaded unconditionally.
    public var withChats: Bool
    public var withAttachments: Bool
    public var withHandle: Bool
    public var withChatParticipants: Bool
    /// The three blob columns, each gated by its own `with` entry.
    ///
    /// Off by default, matching `DEFAULT_MESSAGE_CONFIG`, and the default is the point:
    /// a decoded `attributedBody` is frequently larger than the rest of the message put
    /// together, so serializing one per row unasked turns a 1000-message page into
    /// something several times the size a client has ever received. They are `null` on the
    /// wire until requested.
    public var withAttributedBody: Bool
    public var withMessageSummaryInfo: Bool
    public var withPayloadData: Bool
    /// Whether an attachment carries `height`, `width` and `metadata`.
    ///
    /// Off unless the caller asks for `attachment.metadata`. Reading it means opening
    /// each attachment off disk, so a page of image messages pays a file probe per row —
    /// which is why the reference makes the message routes opt in even though the
    /// serializer's own default is on.
    public var withAttachmentMetadata: Bool

    public init(
      chatGUID: String? = nil,
      limit: Int = 100,
      offset: Int = 0,
      ascending: Bool = false,
      after: Date? = nil,
      before: Date? = nil,
      withChats: Bool = false,
      withAttachments: Bool = false,
      withHandle: Bool = true,
      withChatParticipants: Bool = false,
      withAttributedBody: Bool = false,
      withMessageSummaryInfo: Bool = false,
      withPayloadData: Bool = false,
      withAttachmentMetadata: Bool = false
    ) {
      self.chatGUID = chatGUID
      self.limit = limit
      self.offset = offset
      self.ascending = ascending
      self.after = after
      self.before = before
      self.withChats = withChats
      self.withAttachments = withAttachments
      self.withHandle = withHandle
      self.withChatParticipants = withChatParticipants
      self.withAttributedBody = withAttributedBody
      self.withMessageSummaryInfo = withMessageSummaryInfo
      self.withPayloadData = withPayloadData
      self.withAttachmentMetadata = withAttachmentMetadata
    }

    /// The attachment config these flags describe.
    public var attachmentConfig: AttachmentSerializerConfig {
      AttachmentSerializerConfig(loadMetadata: withAttachmentMetadata)
    }

    /// The serializer config these flags describe.
    ///
    /// Each `with` flag is honoured rather than passing `.full` unconditionally. The
    /// reference gates `attributedBody`, `messageSummaryInfo` and `payloadData` behind `with`
    /// and defaults them to `null`; measured against a live Electron server, that is the
    /// difference between `"attributedBody": null` and a fully expanded run array on every
    /// row of every page.
    public var serializerConfig: MessageSerializerConfig {
      MessageSerializerConfig(
        parseAttributedBody: withAttributedBody,
        parseMessageSummary: withMessageSummaryInfo,
        parsePayloadData: withPayloadData,
        loadChatParticipants: withChatParticipants,
        includeChats: true
      )
    }

    /// Parses the shape clients send.
    ///
    /// `with` is a list of relation names, and the reference accepts several
    /// spellings for the same thing (`chat.participants`, `chats`). Matching on a
    /// contained substring rather than equality reproduces that tolerance.
    public static func parse(_ body: JSONValue) -> Query {
      let relations = (body["with"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        .map { $0.lowercased() }
      func wants(_ name: String) -> Bool {
        relations.contains { $0.contains(name) }
      }

      return Query(
        chatGUID: body["chatGuid"]?.stringValue,
        limit: body["limit"]?.intValue ?? 100,
        offset: body["offset"]?.intValue ?? 0,
        ascending: (body["sort"]?.stringValue ?? "DESC").uppercased() == "ASC",
        after: body["after"]?.intValue.map { Date(timeIntervalSince1970: Double($0) / 1000) },
        before: body["before"]?.intValue.map { Date(timeIntervalSince1970: Double($0) / 1000) },
        withChats: wants("chat"),
        withAttachments: wants("attachment"),
        withHandle: !relations.isEmpty ? wants("handle") : true,
        withChatParticipants: wants("participant"),
        // Both spellings, because the reference accepts both and clients use both.
        withAttributedBody: wants("attributedbody") || wants("attributed-body"),
        withMessageSummaryInfo: wants("messagesummaryinfo") || wants("message-summary-info"),
        withPayloadData: wants("payloaddata") || wants("payload-data"),
        withAttachmentMetadata: wants("attachment.metadata") || wants("attachments.metadata")
      )
    }
  }

  /// A message together with the relations that were loaded alongside it.
  ///
  /// What this layer returns instead of pre-serialized JSON. The wire form is produced at
  /// the HTTP edge by `serialize`, which is the same serializer call as before, one layer
  /// up — so the bytes are unchanged and the parity fixtures prove it.
  ///
  /// Absent-vs-null is unaffected by the move, and that is worth stating because it looks
  /// like the thing that would break: whether `dateEdited` appears at all is decided by
  /// `profile.supportsEditedMessages` INSIDE the serializer, not by whether a value here is
  /// nil. The projection carries rows; the profile still decides the shape.
  public struct MessageProjection: Sendable {
    public let row: IMessageRow
    public let relations: MessageSerializer.Context
  }

  public func query(_ query: Query) async throws -> [MessageProjection] {
    let rows = try await repository.messages(
      MessageRepository.MessageQuery(
        chatGUID: query.chatGUID,
        after: query.after,
        before: query.before,
        limit: query.limit,
        offset: query.offset,
        ascending: query.ascending,
        requiresChat: query.withChats
      )
    )
    return try await project(rows, query: query)
  }

  /// What Send Later is still holding, soonest first, hydrated like any listing so a client
  /// can show them in the transcript. `dateCreated` on each is the DELIVERY time.
  public func pendingScheduledMessages(
    chatGUID: String? = nil, query: Query = Query()
  ) async throws -> [MessageProjection] {
    let rows = try await repository.pendingScheduledMessages(chatGUID: chatGUID)
    return try await project(rows, query: query)
  }

  public func find(
    guid: String, query: Query = Query()
  ) async throws -> MessageProjection? {
    guard let row = try await repository.message(guid: guid) else { return nil }
    return try await project([row], query: query).first
  }

  /// Wire form, for the HTTP layer.
  public func serialize(_ projections: [MessageProjection], query: Query) -> [JSONValue] {
    projections.map { projection in
      serializer.serialize(
        projection.row, context: projection.relations,
        config: query.serializerConfig,
        attachmentConfig: query.attachmentConfig
      )
    }
  }

  /// Wire form under an explicit serializer configuration, for routes whose shape is fixed
  /// by the route rather than by a query — hydration sends `.full` regardless.
  public func serialize(
    _ projections: [MessageProjection], config: MessageSerializerConfig
  ) -> [JSONValue] {
    projections.map { serializer.serialize($0.row, context: $0.relations, config: config) }
  }

  public func serialize(_ projection: MessageProjection, query: Query) -> JSONValue {
    serialize([projection], query: query)[0]
  }

  public func count(
    chatGUID: String? = nil,
    after: Date? = nil,
    before: Date? = nil,
    onlyFromMe: Bool = false,
    requiresChat: Bool = false
  ) async throws -> Int {
    try await repository.messageCount(
      MessageRepository.MessageQuery(
        chatGUID: chatGUID, after: after, before: before,
        onlyFromMe: onlyFromMe, requiresChat: requiresChat
      )
    )
  }

  /// Loads relations and serializes.
  ///
  /// Relations are fetched per message rather than in one pass. That is the honest simple
  /// version and it is not the bottleneck at these page sizes. If it becomes one, the fix
  /// is a batched fetch here — possible precisely because it is one function rather than
  /// fifteen call sites.
  /// Loads whatever relations the query asked for. Exactly what the old private
  /// `serialize` did, minus the final serializer call.
  /// Not `private`: `MessageSending.swift` and `MessageMutation.swift` are extensions on
  /// this type in other files, and `private` is file-scoped. Still module-internal.
  func project(
    _ rows: [IMessageRow], query: Query
  ) async throws -> [MessageProjection] {
    var results: [MessageProjection] = []
    for row in rows {
      var context = MessageSerializer.Context()

      if query.withHandle, let handleID = row.handleID {
        context.handle = try await repository.handle(rowID: handleID)
      }
      if query.withChats {
        context.chats = try await repository.chats(forMessageGUID: row.guid)
      }
      if query.withAttachments {
        context.attachments = try await repository.attachments(forMessageGUID: row.guid)
        // Read off disk only when asked. `withAttachmentMetadata` is what gates the file
        // probe — see `Query`, whose header says why it is opt-in — and the reader caches
        // by GUID so a page that repeats an attachment pays once.
        if query.withAttachmentMetadata {
          for attachment in context.attachments {
            context.attachmentMetadata[attachment.guid] =
              await attachmentMetadata.metadata(for: attachment)
          }
        }
      }
      results.append(MessageProjection(row: row, relations: context))
    }
    return results
  }

  /// The messages behind a set of GUIDs, with no relations loaded.
  ///
  /// For the hydration route: a client holding notification payloads asks for the full
  /// messages behind them. Deduplicated, because a message in several chats produces several
  /// notifications and the client should not pay for the same lookup twice.
  ///
  /// A GUID that no longer resolves is OMITTED rather than erroring the batch. A message
  /// deleted between the notification and the hydration is normal, and failing the whole
  /// request would lose the eleven that were fine.
  public func hydrate(guids: [String]) async throws -> [MessageProjection] {
    var seen = Set<String>()
    var results: [MessageProjection] = []
    for guid in guids where seen.insert(guid).inserted {
      guard let row = try await repository.message(guid: guid) else { continue }
      results.append(MessageProjection(row: row, relations: MessageSerializer.Context()))
    }
    return results
  }

  /// How many messages were delivered or read in a window.
  ///
  /// `after` is required by the route rather than by this method — without one the question
  /// is "how many messages have ever been delivered or read", which is every message and is
  /// not what any client wants. The refusal belongs at the edge, so this stays a plain read.
  public func updatedCount(after: Date, before: Date? = nil) async throws -> Int {
    try await repository.updatedMessageCount(after: after, before: before)
  }
}
