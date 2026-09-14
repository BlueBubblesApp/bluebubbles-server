//  MessageInterface
//  Message operations, independent of how they were asked for.
//
//  Controllers stay thin and delegate here, and the same methods serve the HTTP routes, the
//  legacy socket commands, and the SwiftUI app.
//
//  It is also where the send-backend decision lives. `MessageInterface` picks between the
//  Private API and AppleScript per operation and reports capability, rather than failing late
//  with an obscure error; see `.claude/docs/imessage.md`.

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
  /// `AttachmentMetadataReader`: this is why it is a stored property rather than built per
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
    /// unless asked for: participants especially, which is where a chat listing spends
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
    /// each attachment off disk, so a page of image messages pays a file probe per row:
    /// which is why the reference makes the message routes opt in even though the
    /// serializer's own default is on.
    public var withAttachmentMetadata: Bool

    /// `convertAttachments`. See `AttachmentSerializerConfig.convert`: it is carried, and
    /// deliberately acted on by nothing, because the conversion it names happens on download
    /// here rather than during serialization.
    public var convertAttachments: Bool

    /// The `where` clause, understood. See `MessageFilter` in BBIMessage.
    ///
    /// Carried on the query rather than passed beside it so the listing and the `total`
    /// that describes it cannot be filtered differently: they were, and a `total` counting
    /// every message in the database against pages of filtered ones is what made the app's
    /// incremental sync ask for 417 pages of a 50-message delta.
    public var filters: [MessageFilter]

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
      withAttachmentMetadata: Bool = false,
      filters: [MessageFilter] = [],
      convertAttachments: Bool = true
    ) {
      self.chatGUID = chatGUID
      // Clamped, matching `MessageQuery` in the repository and every other paged route
      // here. The value reaches `LIMIT ?` directly, and **SQLite reads a negative LIMIT as
      // no limit**, so `{"limit": -1}` meant "every message in the database", decoded and
      // serialised. A client asking for more than the cap has always been given the cap.
      self.limit = min(max(1, limit), 1000)
      self.offset = max(0, offset)
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
      self.filters = filters
      self.convertAttachments = convertAttachments
    }

    /// The attachment config these flags describe.
    public var attachmentConfig: AttachmentSerializerConfig {
      // `convertAttachments` is carried through rather than dropped, so the flag a client
      // sent is visible where it lands; see `AttachmentSerializerConfig.convert` for why
      // nothing reads it and why that is not a gap.
      AttachmentSerializerConfig(
        convert: convertAttachments, loadMetadata: withAttachmentMetadata)
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
    ///
    /// **Throws on a `where` clause this server does not understand**, rather than dropping
    /// it. A filter that is accepted and not applied answers the wrong question with a 200,
    /// which is how a sync asking for "messages after ROWID n" was handed the newest
    /// thousand messages instead and never noticed. See `MessageFilter`.
    public static func parse(_ body: JSONValue) throws -> Query {
      let relations = (body["with"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        .map { $0.lowercased() }
      /// SUBSTRING, where the reference uses exact membership
      /// (`arrayHasOne(withQuery, ["chats", "chat"])`, `messageRouter.ts:78`). So
      /// `with: ["chat.participants"]` turns `withChats` on here and does not there.
      ///
      /// Deliberately LEFT as it is, and this is the project's own rule rather than
      /// inertia: an extra field of ours is tolerable because clients ignore what they do
      /// not know, while a MISSING field is the break. Matching the reference here would
      /// REMOVE `chats` from the response for anybody asking only for
      /// `chat.participants` — turning a tolerable difference into the one kind that
      /// cannot be taken back. Recorded so the divergence is a decision rather than a
      /// find.
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
        // ALWAYS. The reference left-joins `message.handle` unconditionally
        // (`databases/imessage/index.ts:256-259`) and has no `withHandle` parameter at all,
        // so asking for chats and attachments returned a populated handle there and a null
        // one here. The recorded fixture happens to name `handle` in its `with` list, which
        // is why the replay never saw it. No comment ever justified the branch.
        withHandle: true,
        withChatParticipants: wants("participant"),
        // Both spellings, because the reference accepts both and clients use both.
        withAttributedBody: wants("attributedbody") || wants("attributed-body"),
        withMessageSummaryInfo: wants("messagesummaryinfo") || wants("message-summary-info"),
        withPayloadData: wants("payloaddata") || wants("payload-data"),
        withAttachmentMetadata: wants("attachment.metadata") || wants("attachments.metadata"),
        filters: try Self.filters(in: body),
        // Absent means true, which is the reference's default.
        convertAttachments: body["convertAttachments"]?.boolValue ?? true
      )
    }

    /// The `where` array, as typed filters.
    ///
    /// The JSON-to-`FilterArgument` step lives HERE rather than in BBIMessage, which owns
    /// the filter and the SQL: that target sits below the wire layer and must not learn the
    /// shape of an HTTP body to read a database.
    static func filters(in body: JSONValue) throws -> [MessageFilter] {
      guard let clauses = body["where"]?.arrayValue else { return [] }
      return try clauses.map { clause in
        // A clause with no `statement` is REFUSED, not skipped. The reference's validator
        // declares `"where.*.statement": "required|string"` and 400s the request, and
        // skipping it here would be the same silent no-op this whole filter exists to end:
        // a client sending a malformed clause would be told nothing and handed unfiltered
        // rows.
        guard let statement = clause["statement"]?.stringValue else {
          throw MessageFilter.Unsupported(statement: "")
        }
        var arguments: [String: FilterArgument] = [:]
        if case .object(let raw)? = clause["args"] {
          for (name, value) in raw {
            switch value {
            case .int(let number): arguments[name] = .number(Int64(number))
            case .int64(let number): arguments[name] = .number(number)
            case .string(let text): arguments[name] = .text(text)
            case .bool(let flag): arguments[name] = .number(flag ? 1 : 0)
            case .array(let values): arguments[name] = .list(values.compactMap(\.stringValue))
            // A double, an object or a null is not something any statement here binds.
            // Left out, so the statement is refused by its own `Unsupported` rather than
            // silently matching with a value it cannot use.
            default: break
            }
          }
        }
        return try MessageFilter.parse(statement: statement, arguments: arguments)
      }
    }
  }

  /// A message together with the relations that were loaded alongside it.
  ///
  /// What this layer returns instead of pre-serialized JSON. The wire form is produced at
  /// the HTTP edge by `serialize`, which is the same serializer call as before, one layer
  /// up, so the bytes are unchanged and the parity fixtures prove it.
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
        requiresChat: query.withChats,
        filters: query.filters
      )
    )
    return try await project(rows, query: query)
  }

  /// What Send Later is still holding, soonest first, hydrated like any listing so a client
  /// can show them in the transcript. `dateCreated` on each is the DELIVERY time.
  public func pendingScheduledMessages(
    chatGUID: String? = nil, query: Query = Query()
  ) async throws -> [MessageProjection] {
    // The read side of the same gate the write routes already apply. `schedule_type` and
    // `schedule_state` are Sequoia columns and the floor is Sonoma, so on macOS 14 this
    // query failed with SQLite's "no such column" and a 500. The capability existed
    // (`SchemaProfile.supportsScheduledMessages`) and nothing called it.
    //
    // Refused rather than answered with an empty list, and the distinction is what a client
    // shows: empty means "nothing scheduled", and the truth here is "this Mac cannot
    // schedule anything". Same sentence as `MessageMutation.requireSendLaterSupported`, so
    // every Send Later route refuses the same way on an unsupported OS.
    guard repository.supportsScheduledMessages else {
      throw InterfaceError.invalidRequest(
        "Send Later is only supported on macOS Sequoia (15) and newer"
      )
    }
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
  /// by the route rather than by a query: hydration sends `.full` regardless.
  public func serialize(
    _ projections: [MessageProjection], config: MessageSerializerConfig
  ) -> [JSONValue] {
    projections.map { serializer.serialize($0.row, context: $0.relations, config: config) }
  }

  public func serialize(_ projection: MessageProjection, query: Query) -> JSONValue {
    serialize([projection], query: query)[0]
  }

  /// - Parameter filters: the same `where` the listing was filtered by.
  ///
  ///   Not optional in practice, for the route that pages: `metadata.total` describes the
  ///   pages `query` returns, so counting without the filter reports the size of the whole
  ///   database and a client divides it by its page size. The bare counts
  ///   (`/message/count`) genuinely have none, which is why it defaults to empty rather
  ///   than being required.
  /// - Parameters:
  ///   - minRowID: `minRowId`, inclusive. Accepted by all three count routes.
  ///   - maxRowID: `maxRowId`, inclusive.
  ///   - updated: count by `date_delivered`/`date_read` rather than `date`, which is what
  ///     `GET /message/count/updated` asks. A flag rather than a separate method, so that
  ///     route gets `chatGuid` and the row-id window for free; it had none of the three.
  public func count(
    chatGUID: String? = nil,
    after: Date? = nil,
    before: Date? = nil,
    onlyFromMe: Bool = false,
    requiresChat: Bool = false,
    filters: [MessageFilter] = [],
    minRowID: Int64? = nil,
    maxRowID: Int64? = nil,
    updated: Bool = false
  ) async throws -> Int {
    try await repository.messageCount(
      MessageRepository.MessageQuery(
        chatGUID: chatGUID, after: after, before: before,
        onlyFromMe: onlyFromMe, requiresChat: requiresChat, filters: filters,
        minRowID: minRowID, maxRowID: maxRowID,
        dateField: updated ? .updated : .created
      )
    )
  }

  /// Loads relations and serializes.
  ///
  /// Relations are fetched for the WHOLE PAGE, in one query each, rather than per message.
  /// Per message they were three statements a row -- a handle lookup, a chats query and an
  /// attachments query -- so a 1000-row page ran 3,000 of them: measured at 143ms, 1.6 times
  /// the cost of fetching the rows themselves, and all of it serialised through the single
  /// database queue, so it head-of-line blocked every other client for the duration. Each
  /// plan was fine on its own; the count was the problem. The comment that used to sit here
  /// said this "is not the bottleneck at these page sizes", and at the 1000-row limit the
  /// route accepts, it was.
  ///
  /// Loads whatever relations the query asked for, leaving the serializer call to the
  /// caller.
  /// Not `private`: `MessageSending.swift` and `MessageMutation.swift` are extensions on
  /// this type in other files, and `private` is file-scoped. Still module-internal.
  func project(
    _ rows: [IMessageRow], query: Query
  ) async throws -> [MessageProjection] {
    var results: [MessageProjection] = []
    // Memoized ACROSS the page, not per message. A conversation's participants are the same
    // for every message in it, and a page is usually a handful of chats: without this a
    // 1000-message page asks the same question a thousand times. `EventHydrator` caches the
    // same lookup for the same reason.
    var participantsByChatGUID: [String: [HandleRow]] = [:]

    // One query each, for the page. Empty when the query did not ask, so nothing is read
    // that would not have been read before.
    let handlesByRowID =
      query.withHandle
      ? try await repository.handles(rowIDs: rows.compactMap(\.handleID))
      : [:]
    let chatsByMessageGUID =
      query.withChats
      ? try await repository.chats(forMessageGUIDs: rows.map(\.guid))
      : [:]
    let attachmentsByMessageGUID =
      query.withAttachments
      ? try await repository.attachments(forMessageGUIDs: rows.map(\.guid))
      : [:]

    for row in rows {
      var context = MessageSerializer.Context()

      if query.withHandle, let handleID = row.handleID {
        context.handle = handlesByRowID[handleID]
      }
      if query.withChats {
        context.chats = chatsByMessageGUID[row.guid] ?? []
        // `chats.participants` was ACCEPTED AND NEVER LOADED, so every chat on a message
        // arrived with an empty participant list and `includeParticipants` rendered it as
        // one. The client works around it by fetching each chat again
        // (`incremental_sync_manager.dart` calls `chat.fetchOne(…, with: participants)` per
        // chat and its comment reasons that the message API omits them "for efficiency"),
        // which is one extra request per chat on every sync of a new conversation.
        if query.withChatParticipants {
          for chat in context.chats {
            if let cached = participantsByChatGUID[chat.guid] {
              context.participantsByChatGUID[chat.guid] = cached
              continue
            }
            let loaded = try await repository.participants(chatGUID: chat.guid)
            participantsByChatGUID[chat.guid] = loaded
            context.participantsByChatGUID[chat.guid] = loaded
          }
        }
      }
      if query.withAttachments {
        context.attachments = attachmentsByMessageGUID[row.guid] ?? []
        // Read off disk only when asked. `withAttachmentMetadata` is what gates the file
        // probe (see `Query`, whose header says why it is opt-in) and the reader caches
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
  /// - Parameter withAttachments: whether to load each message's attachments. The handle
  ///   and the chats are ALWAYS loaded and are not optional, because this route exists to
  ///   turn a notification into a message a client can display and file.
  public func hydrate(
    guids: [String], withAttachments: Bool = false
  ) async throws -> [MessageProjection] {
    // Through `project`, like every other read, rather than building empty contexts.
    //
    // This used to hand back `MessageSerializer.Context()` for every message, so hydration
    // answered `handle: null`, `chats: []` and `attachments: []` unconditionally — and the
    // `withAttachments` flag the handler parsed was read nowhere in the source. That is the
    // worst place in the API for it: hydration IS the notification path, and the codec that
    // turns an event into a notification reads `payload.handle.address`. A client hydrating
    // a burst received messages it could not attribute to a sender or place in a
    // conversation, with a 200 and a well-formed body.
    let query = Query(
      withChats: true,
      withAttachments: withAttachments,
      withHandle: true,
      withChatParticipants: true
    )
    // ONE query per batch, through the `guidIn` filter that already existed. This was a
    // lookup per GUID -- 100 statements to hydrate 100 notifications -- on precisely the
    // path where that matters: hydration IS the notification path, so it runs during the
    // bursts, and every one of those queries serialises through the single database queue.
    //
    // Chunked because SQLite's default host-parameter limit is 999 and a client may hand
    // over more GUIDs than that.
    var seen = Set<String>()
    let wanted = guids.filter { seen.insert($0).inserted }
    var rows: [IMessageRow] = []
    for chunk in wanted.chunked(into: MessageRepository.hydrationChunk) {
      var batch = MessageRepository.MessageQuery(limit: chunk.count, offset: 0)
      batch.filters = [.guidIn(chunk)]
      rows += try await repository.messages(batch)
    }
    // The CALLER's order, which a single query cannot give: SQLite returns rows in the
    // order its plan reaches them, and a client hydrating a burst files them in the order
    // it asked. A GUID that no longer resolves is omitted, as before.
    let byGUID = Dictionary(rows.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first })
    return try await project(wanted.compactMap { byGUID[$0] }, query: query)
  }

}
