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
import BBCore
import BBIMessage
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import Foundation
import Logging

public struct MessageInterface: MessagesBackedInterface {

  private let repository: MessageRepository
  private let serializer: MessageSerializer
  let privateAPI: (any PrivateAPI)?
  private let appleScript: AppleScriptMessageSender
  private let formatter: AddressFormatter
  let logger: Logger

  /// Attachment dimensions and durations, cached across requests. See
  /// `AttachmentMetadataReader` — this is why it is a stored property rather than built per
  /// call: the cache is the point.
  let attachmentMetadata = AttachmentMetadataReader()

  public init(
    repository: MessageRepository,
    serializer: MessageSerializer,
    privateAPI: (any PrivateAPI)? = nil,
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
    /// `with` is a list of relation names, and the current server accepts several
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
  private func project(
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

  // MARK: - Sending

  /// Which backend a send will use.
  ///
  /// Reported rather than discovered: the Private API is an enhancement, not a
  /// prerequisite, and a user without it should be told what they have rather than meeting
  /// a failure at the moment they try to send.
  public enum SendBackend: String, Sendable {
    case privateAPI = "private-api"
    case appleScript = "apple-script"
  }

  public func availableBackend() async -> SendBackend {
    if let privateAPI, await privateAPI.isConnected { return .privateAPI }
    return .appleScript
  }

  /// What a send produced.
  ///
  /// The two backends confirm a send differently, and neither confirms it the way the
  /// other does: the Private API reports the GUID Messages assigned, while AppleScript reports
  /// the chat it resolved the send to and no GUID at all. Both facts are kept so a caller can
  /// correlate whichever it has with the row the change detector later announces.
  public struct SendOutcome: Sendable {
    public let backend: SendBackend
    /// The GUID Messages assigned, when the backend reports one.
    public let messageGUID: String?
    /// The chat the message was sent to, as the backend resolved it.
    public let chatGUID: String?
    /// The row Messages wrote, once it appeared. See `awaitSentMessage`.
    ///
    /// Optional because hydration can time out and a send that reached Messages must not be
    /// reported as a failure because the row was slow — see `serialize`, which falls back to
    /// the identifiers.
    public let message: MessageProjection?

    public init(
      backend: SendBackend,
      messageGUID: String? = nil,
      chatGUID: String? = nil,
      message: MessageProjection? = nil
    ) {
      self.backend = backend
      self.messageGUID = messageGUID
      self.chatGUID = chatGUID
      self.message = message
    }
  }

  // MARK: - Hydrating a send
  //
  // A send answers with the MESSAGE, not with an identifier. That is the reference's
  // contract on all three send routes and it was the biggest v1 divergence left: this server
  // returned `{guid, chatGuid, backend}`, so a client that reads back the text, the date, the
  // handle or the chats it just sent to got none of them, and had to go and ask again.
  //
  // Messages writes the row ASYNCHRONOUSLY, so the row is not there when the send call
  // returns. Both backends need a bounded wait, and they need different ones:
  //
  //   - The Private API reports the GUID Messages assigned, so the wait is a lookup by GUID.
  //   - AppleScript reports nothing but the chat it resolved, so the wait is a search for a
  //     message we sent, to that chat, with that text, since just before we asked.
  //
  // The reference does the same two things by different means — a `MessagePromise` registered
  // with its message manager, resolved either by GUID or by a text match on the next poll of
  // `chat.db`. The shape below is the same idea without the manager: this server has one
  // caller waiting on one row, and a promise registry would be machinery for a queue of one.

  /// How long to wait for a sent row, and how eagerly to look.
  ///
  /// 250 ms, then ×1.5, to a 60-second ceiling — the reference's `resultAwaiter` defaults,
  /// kept because the thing being waited on is the same and its timing is Apple's. The
  /// backoff matters more than it looks: a tight loop against `chat.db` while Messages is
  /// mid-write is the read pattern most likely to sit behind its lock.
  ///
  /// 60 seconds fits inside the route's 300-second response timeout, so a slow send answers
  /// slowly rather than being cut off with no body at all.
  struct SendHydrationPolicy: Sendable {
    var initialDelay: Duration = .milliseconds(250)
    var multiplier: Double = 1.5
    var limit: Duration = .seconds(60)

    static let standard = SendHydrationPolicy()

    /// For an edit, an unsend or a notify: the reference allows these THIRTY seconds where a
    /// send gets sixty. Transcribed rather than unified — the wait is for a column to move
    /// on a row that already exists, which is a faster thing to happen than a row being
    /// written, and halving the ceiling halves how long a client hangs when it never does.
    static let mutation = SendHydrationPolicy(limit: .seconds(30))
  }

  /// Waits for the row behind a Private API send and loads it the way the reference does:
  /// with its handle and its chats, without the chats' participants.
  ///
  /// Returns nil on timeout rather than throwing. **The send already happened.** Turning a
  /// slow write into a 500 would tell a client its message failed when it is on its way, and
  /// the client would send it again — which is the one failure mode worth more than a
  /// complete response body.
  func awaitSentMessage(
    guid: String, policy: SendHydrationPolicy = .standard
  ) async throws -> MessageProjection? {
    try await awaitJoined(policy: policy) {
      try await self.find(guid: guid, query: Self.sendQuery)
    }
  }

  /// Waits for the row AND for its `chat_message_join` — they do not arrive together.
  ///
  /// MEASURED against a live send: Messages writes the `message` row first and joins it to
  /// the chat a moment later, so a wait that stops at "the row exists" answers with
  /// `chats: []`. The reference's recorded send carries the chat, and a client reads it to
  /// place the message it just sent — an empty array puts it nowhere.
  ///
  /// This was invisible to every test that did not go through Messages: a fixture database
  /// has its joins already written, so the race cannot occur there. It is the one bug the
  /// mock could not have shown.
  ///
  /// On timeout it answers with the last row it saw, joins or not. A message with no chats
  /// is a worse answer than one with them and a far better answer than none: the send
  /// happened either way.
  private func awaitJoined(
    policy: SendHydrationPolicy,
    _ load: () async throws -> MessageProjection?
  ) async throws -> MessageProjection? {
    var lastSeen: MessageProjection?
    let joined = try await poll(policy: policy) {
      guard let projection = try await load() else { return nil }
      lastSeen = projection
      return projection.relations.chats.isEmpty ? nil : projection
    }
    return joined ?? lastSeen
  }

  /// The AppleScript equivalent: no GUID to look up, so the row is identified by what was
  /// sent and where.
  ///
  /// `sentAfter` is stamped ten seconds before the send, matching the reference's own offset
  /// — Messages' `date` is not reliably later than the moment we asked, and a window that
  /// starts exactly at the send misses a row Messages back-dated by a second.
  ///
  /// Ambiguity is resolved toward the NEWEST match, and it is genuinely ambiguous: two
  /// identical messages to the same chat inside the window are indistinguishable. That is
  /// the same limit the reference has, for the same reason, and it is why the Private API
  /// path is preferred whenever it is available.
  func awaitSentMessage(
    inChat chatGUID: String, text: String, sentAfter: Date,
    policy: SendHydrationPolicy = .standard
  ) async throws -> MessageProjection? {
    try await awaitJoined(policy: policy) {
      let rows = try await self.repository.messages(
        MessageRepository.MessageQuery(
          chatGUID: chatGUID, after: sentAfter, limit: 25,
          ascending: false, onlyFromMe: true
        )
      )
      // `universalText()`, NOT the `text` column. MEASURED against a live AppleScript send:
      // Messages writes the row with `text` NULL and the words only in `attributedBody`,
      // and it stays that way — the API's own `text` field is `universalText()` for exactly
      // this reason. Matching the raw column meant this never matched at all: every
      // AppleScript send waited out the full sixty seconds and fell back to the identifier.
      //
      // Invisible to any fixture, because a fixture database has `text` populated. The
      // reference matches on its own `universalText()` for the same reason.
      guard let row = rows.first(where: { $0.universalText() == text }) else { return nil }
      return try await self.project([row], query: Self.sendQuery).first
    }
  }

  /// The newest message we sent to a chat inside the window, whatever its text.
  ///
  /// For the AppleScript attachment send, which has no text to match on.
  func awaitNewestSentMessage(
    inChat chatGUID: String, sentAfter: Date, policy: SendHydrationPolicy = .standard
  ) async throws -> MessageProjection? {
    try await awaitJoined(policy: policy) {
      let rows = try await self.repository.messages(
        MessageRepository.MessageQuery(
          chatGUID: chatGUID, after: sentAfter, limit: 1,
          ascending: false, onlyFromMe: true
        )
      )
      guard let row = rows.first else { return nil }
      return try await self.project([row], query: Self.sendQuery).first
    }
  }

  /// Ten seconds before now — the reference's own offset, and it is load-bearing.
  ///
  /// Messages' `date` column is not reliably later than the moment the send was asked for,
  /// so a window opening at the send misses rows it back-dated. The cost of the slack is
  /// that a message sent to the same chat in the last ten seconds can be matched instead,
  /// which is why the text match narrows it and why the Private API path does not use this
  /// at all.
  static func hydrationWindowStart() -> Date { Date().addingTimeInterval(-10) }

  /// What a send's response carries: the handle, the chats, and the attachments WITH their
  /// metadata.
  ///
  /// Matches `getMessage(guid, withChats: true, withParticipants: false)` at the reference's
  /// send call sites, serialised under `DEFAULT_ATTACHMENT_CONFIG` — whose `loadMetadata` is
  /// true, which is where `height`, `width` and `metadata` come from.
  ///
  /// Attachments were omitted here on the reasoning that a text send has none and an
  /// attachment send's row is written before its transfer completes. Both halves are true
  /// and the conclusion was wrong: the reference's recorded attachment send carries the
  /// attachment, its dimensions and its `transferState`, and a client uses them to render
  /// what it just sent. A text send simply gets `[]`, which costs one query.
  static let sendQuery = Query(
    withChats: true, withAttachments: true, withHandle: true, withAttachmentMetadata: true
  )

  /// Not `@Sendable`: the loop runs sequentially in one task, and the callers need to keep
  /// hold of the best answer seen so far — see `awaitSentMessage`, whose fallback depends on
  /// capturing a mutable local.
  private func poll(
    policy: SendHydrationPolicy,
    _ attempt: () async throws -> MessageProjection?
  ) async throws -> MessageProjection? {
    if let found = try await attempt() { return found }

    var delay = policy.initialDelay
    var elapsed = Duration.zero
    while elapsed < policy.limit {
      try await Task.sleep(for: delay)
      elapsed += delay
      if let found = try await attempt() { return found }
      delay = delay * policy.multiplier
    }
    return nil
  }

  /// The wire shape of a send: the serialised message, and `tempGuid` if the client sent one.
  ///
  /// `.full` is the reference's send config exactly — `parseAttributedBody`,
  /// `parseMessageSummary` and `parsePayloadData` on, participants off. A send is the one
  /// read where the blob columns are not opt-in: the client is being handed back the message
  /// it just composed, and the reference has always parsed them here.
  ///
  /// **There is no `backend` key.** `POST /message/text` carried one, naming which send path
  /// ran, from the first commit of this server — and nothing ever read it: no client was
  /// told it exists, the reference has never sent it, and the comment justifying it claimed
  /// clients "read this to confirm it took", which they cannot have. The case it would cover
  /// does not arise either: a request for a subject, effect or reply that only AppleScript
  /// can serve is REFUSED rather than quietly downgraded (see `sendText`), and for a plain
  /// message the two backends are indistinguishable in the result. `SendOutcome.backend`
  /// still records which ran, for the log and for the caller; it is not on the wire.
  ///
  /// The identifier fallback below is what happens when hydration timed out. It is not the
  /// contract and it is not meant to be reached; it is there because a send that Messages
  /// accepted must answer 200 with SOMETHING a client can correlate, rather than failing and
  /// inviting a duplicate send.
  public func serialize(_ outcome: SendOutcome, tempGUID: String? = nil) -> JSONValue {
    guard let message = outcome.message else {
      var object = JSONObjectBuilder()
      object.set("guid", outcome.messageGUID.map(JSONValue.string))
      object.set("chatGuid", outcome.chatGUID.map(JSONValue.string))
      object.set("tempGuid", tempGUID.map(JSONValue.string))
      return object.build()
    }

    var serialized = serializer.serialize(
      message.row, context: message.relations, config: .full
    )
    // Merged after serialising, not passed in: `tempGuid` is the client's own correlation
    // token echoed back, not a column, and it is absent when the client sent none.
    if let tempGUID {
      serialized = serialized.merging(["tempGuid": .string(tempGUID)])
    }
    return serialized
  }

  /// Whether the row Messages wrote records a failure.
  ///
  /// A send can be accepted and then fail, and the reference reports that as a 500 carrying
  /// the message — `IMessageError`, "Message sent with an error. See attached message" —
  /// rather than as a 200. It is the most depended-on error response in the API: clients read
  /// `data.error` to show a red exclamation mark against the message they just sent.
  public static func sendFailed(_ outcome: SendOutcome) -> Bool {
    (outcome.message?.row.error ?? 0) != 0
  }

  public struct SendTextRequest: Sendable {
    public var chatGUID: String
    public var text: String
    public var subject: String?
    public var effectID: String?
    public var replyToGUID: String?
    public var partIndex: Int
    public var scanForLinks: Bool
    /// Inline styles and effects by UTF-16 range. Private API only, macOS 15 and later.
    public var formatting: [FormattedRange]
    /// Forces AppleScript even when the Private API is available. The current server
    /// exposes this as `method`, and clients use it.
    public var forcedBackend: SendBackend?

    public init(
      chatGUID: String,
      text: String,
      subject: String? = nil,
      effectID: String? = nil,
      replyToGUID: String? = nil,
      partIndex: Int = 0,
      scanForLinks: Bool = false,
      formatting: [FormattedRange] = [],
      forcedBackend: SendBackend? = nil
    ) {
      self.chatGUID = chatGUID
      self.text = text
      self.subject = subject
      self.effectID = effectID
      self.replyToGUID = replyToGUID
      self.partIndex = partIndex
      self.scanForLinks = scanForLinks
      self.formatting = formatting
      self.forcedBackend = forcedBackend
    }
  }

  /// Sends a text message through whichever backend is available.
  ///
  /// The Private API is preferred when connected because it supports subjects, effects and
  /// replies; AppleScript supports none of those. When a request asks for a feature the
  /// chosen backend cannot deliver, that is reported rather than silently dropped — a reply
  /// that arrives as an ordinary message looks like the server ignored the user.
  public func sendText(_ request: SendTextRequest) async throws -> SendOutcome {
    let backend: SendBackend
    if let forced = request.forcedBackend {
      backend = forced
    } else {
      backend = await availableBackend()
    }
    try Self.checkFormatting(request.formatting, text: request.text)

    switch backend {
    case .privateAPI:
      guard let privateAPI else {
        throw InterfaceError.unavailable("the Private API is not available")
      }
      let sent = try await throughMessages {
        try await privateAPI.sendMessage(
          SendMessageRequest(
            chat: ChatIdentifier(request.chatGUID),
            text: request.text,
            subject: request.subject,
            effectId: request.effectID,
            replyTo: request.replyToGUID.map { MessageGUID($0) },
            replyPartIndex: request.partIndex,
            scanForLinks: request.scanForLinks,
            formatting: request.formatting
          )
        )
      }
      return SendOutcome(
        backend: backend,
        messageGUID: sent.guid.rawValue,
        message: try await awaitSentMessage(guid: sent.guid.rawValue)
      )

    case .appleScript:
      // Stated rather than dropped. A client that asked for a reply and got a plain
      // message would look like the server ignored it.
      if request.subject != nil || request.effectID != nil || request.replyToGUID != nil
        || !request.formatting.isEmpty
      {
        throw InterfaceError.invalidRequest(
          "subjects, effects, replies and text formatting need the Private API; this "
            + "server is sending through AppleScript"
        )
      }
      // Stamped BEFORE the send. Messages back-dates rows by a second or so, and a window
      // that opens after the script returns misses them.
      let sentAt = Self.hydrationWindowStart()
      let resolved = try await throughMessages {
        try await appleScript.send(chatGUID: request.chatGUID, text: request.text)
      }
      return SendOutcome(
        backend: backend,
        chatGUID: resolved,
        message: try await awaitSentMessage(
          inChat: resolved, text: request.text, sentAfter: sentAt
        )
      )
    }
  }

  /// Sends one file.
  ///
  /// The reply, effect and subject fields are the reference's `sendAttachmentSync`
  /// parameters (`subject`, `effectId`, `selectedMessageGuid`, `partIndex`), and its
  /// validator forces the Private API whenever one is present. The helper's single-file
  /// action carries none of them, so a send that names one goes through the multipart
  /// action as a one-part message instead — same file, same row, with the association
  /// the client asked for. A voice memo cannot travel that way (`isAudioMessage` is its own
  /// composition), so an audio message keeps the plain path and the fields are refused
  /// rather than silently dropped.
  public func sendAttachment(
    chatGUID: String,
    filePath: String,
    isAudioMessage: Bool = false,
    subject: String? = nil,
    effectID: String? = nil,
    replyToGUID: String? = nil,
    partIndex: Int? = nil
  ) async throws -> SendOutcome {
    let backend = await availableBackend()
    guard FileManager.default.fileExists(atPath: filePath) else {
      throw InterfaceError.invalidRequest("no file at \(filePath)")
    }

    if subject != nil || effectID != nil || replyToGUID != nil {
      guard !isAudioMessage else {
        throw InterfaceError.invalidRequest(
          "a voice memo cannot carry a subject, an effect or a reply"
        )
      }
      return try await sendMultipart(
        chatGUID: chatGUID,
        parts: [MessagePart(attachmentPath: filePath)],
        subject: subject,
        effectID: effectID,
        replyToGUID: replyToGUID,
        partIndex: partIndex
      )
    }

    switch backend {
    case .privateAPI:
      guard let privateAPI else {
        throw InterfaceError.unavailable("the Private API is not available")
      }
      let sent = try await throughMessages {
        try await privateAPI.sendAttachment(
          SendAttachmentRequest(
            chat: ChatIdentifier(chatGUID),
            // Messages cannot read outside its container; see AttachmentStaging.
            filePath: try AttachmentStaging.stage(filePath),
            isAudioMessage: isAudioMessage
          )
        )
      }
      return SendOutcome(
        backend: backend,
        messageGUID: sent.guid.rawValue,
        message: try await awaitSentMessage(guid: sent.guid.rawValue)
      )

    case .appleScript:
      // The attachment row's `text` is the transfer's filename placeholder, not anything
      // the caller supplied, so there is no text to match on. The reference has the same
      // problem and solves it the same way — its awaiter is registered with the attachment
      // NAME as the text — so the window plus "from me, newest, in this chat" is what
      // identifies it.
      let sentAt = Self.hydrationWindowStart()
      let resolved = try await throughMessages {
        try await appleScript.send(chatGUID: chatGUID, attachmentPath: filePath)
      }
      return SendOutcome(
        backend: backend,
        chatGUID: resolved,
        message: try await awaitNewestSentMessage(inChat: resolved, sentAfter: sentAt)
      )
    }
  }

  /// Sends a message assembled from ordered parts — text, attachments and mentions
  /// interleaved.
  ///
  /// Private-API only, and deliberately not falling back: AppleScript can send text and it
  /// can send a file, but it cannot produce ONE message containing both in a chosen order.
  /// Falling back would silently turn a single rich message into several plain ones, which
  /// is a worse outcome than a clear refusal.
  public func sendMultipart(
    chatGUID: String,
    parts: [MessagePart],
    subject: String? = nil,
    effectID: String? = nil,
    replyToGUID: String? = nil,
    partIndex: Int? = nil
  ) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "multipart messages")
    guard !parts.isEmpty else {
      throw InterfaceError.invalidRequest("at least one part is required")
    }
    for part in parts {
      try Self.checkFormatting(part.formatting, text: part.text ?? "")
    }
    for part in parts {
      guard let path = part.attachmentPath else { continue }
      guard FileManager.default.fileExists(atPath: path) else {
        throw InterfaceError.invalidRequest("no file at \(path)")
      }
    }

    let sent = try await throughMessages {
      try await api.sendMultipart(
        SendMultipartRequest(
          chat: ChatIdentifier(chatGUID),
          parts: try AttachmentStaging.stage(parts: parts),
          subject: subject,
          effectId: effectID,
          replyTo: replyToGUID.map { MessageGUID($0) },
          replyPartIndex: partIndex
        )
      )
    }
    return SendOutcome(
      backend: .privateAPI,
      messageGUID: sent.guid.rawValue,
      message: try await awaitSentMessage(guid: sent.guid.rawValue)
    )
  }

  // MARK: - Private-API-only operations
  //
  // Each of these throws `unavailableWithoutPrivateAPI` rather than a generic failure, so a
  // client can tell "this needs a feature you do not have" from "this went wrong".

  /// Sends a tapback and answers with the tapback's OWN message.
  ///
  /// A reaction is an ordinary message carrying an association, so it gets a row of its own
  /// and the route returns that row — not the message being reacted to. Same hydration as a
  /// send, because it IS a send.
  public func react(
    chatGUID: String,
    targetGUID: String,
    reaction: String,
    partIndex: Int = 0,
    emoji: String? = nil
  ) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "reactions")
    guard let type = ReactionType(rawValue: reaction) else {
      throw InterfaceError.invalidRequest("unknown reaction type: \(reaction)")
    }
    // `emoji` / `-emoji` carry the emoji in its own field; without one there is nothing
    // to send. A named tapback ignores the field rather than refusing it.
    if type.isEmoji {
      try Self.checkEmojiReactionSupported()
      if (emoji ?? "").isEmpty {
        throw InterfaceError.invalidRequest("an `emoji` is required for the emoji reaction")
      }
    }
    // The reference reads the target first and refuses a reaction to a message it does not
    // have, before reaching Messages at all — so a bad `selectedMessageGuid` is a 400 rather
    // than whatever IMCore says about it.
    try await requireMessage(targetGUID)

    let sent = try await throughMessages {
      try await api.react(
        ReactionRequest(
          chat: ChatIdentifier(chatGUID),
          target: MessageGUID(targetGUID),
          reaction: type,
          partIndex: partIndex,
          emoji: type.isEmoji ? emoji : nil
        )
      )
    }
    return SendOutcome(
      backend: .privateAPI,
      messageGUID: sent.guid.rawValue,
      message: try await awaitSentMessage(guid: sent.guid.rawValue)
    )
  }

  /// Places a sticker on a message part and answers with the sticker's OWN message.
  ///
  /// The reaction route's shape with an attachment's input: a sticker is an association
  /// (`associatedMessageType` 1000, the value the serializer already spells `"sticker"`)
  /// whose payload is a file transfer, so it needs the target message a tapback needs and
  /// the staged file an attachment needs. Same hydration as a send, because it IS a send —
  /// the row appears in chat.db with `associated_message_guid = p:<part>/<target>` and an
  /// attachment row flagged `is_sticker`.
  ///
  /// Private API only: AppleScript has no notion of an association at all.
  public func sendSticker(
    chatGUID: String,
    filePath: String,
    targetGUID: String,
    partIndex: Int = 0,
    placement: StickerPlacement = .centered
  ) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "stickers")
    guard FileManager.default.fileExists(atPath: filePath) else {
      throw InterfaceError.invalidRequest("no file at \(filePath)")
    }
    // As `react`: a target this server does not have is a 400, before Messages is asked.
    try await requireMessage(targetGUID)

    let sent = try await throughMessages {
      try await api.sendSticker(
        SendStickerRequest(
          chat: ChatIdentifier(chatGUID),
          // Messages cannot read outside its container; see AttachmentStaging.
          filePath: try AttachmentStaging.stage(filePath),
          target: MessageGUID(targetGUID),
          partIndex: partIndex,
          placement: placement
        )
      )
    }
    return SendOutcome(
      backend: .privateAPI,
      messageGUID: sent.guid.rawValue,
      message: try await awaitSentMessage(guid: sent.guid.rawValue)
    )
  }

  /// Emoji reactions arrived with macOS 15 / iOS 18 and are refused below it, before the
  /// helper is asked: Sonoma has neither `IMEmojiTapback` nor `IMTapbackSender`, and the
  /// fallback send path there cannot carry an emoji. Same shape as the text-formatting gate.
  static func checkEmojiReactionSupported(
    majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  ) throws {
    guard majorVersion >= 15 else {
      throw InterfaceError.invalidRequest(
        "Emoji reactions are only supported on macOS Sequoia (15) and newer"
      )
    }
  }

  /// The reference's two gates on `textFormatting`, then its range rules.
  ///
  /// macOS 15 is where the attributes appeared; the reference refuses below it with this
  /// sentence, and so does this. Ranges are checked against the UTF-16 length, because
  /// that is the unit the attributes are applied in.
  static func checkFormatting(_ ranges: [FormattedRange], text: String) throws {
    guard !ranges.isEmpty else { return }
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 15 {
      throw InterfaceError.invalidRequest(
        "Text formatting is only supported on macOS Sequoia (15) and newer"
      )
    }
    do {
      try FormattedRange.validate(ranges, utf16Length: text.utf16.count)
    } catch let error as TextFormattingError {
      throw InterfaceError.invalidRequest(error.description)
    }
  }

  /// The row behind a GUID, or the reference's refusal.
  ///
  /// `invalidRequest` — a 400 — and not `notFound`. It reads wrong and it is what ships: the
  /// reference's message-action routes all open with
  /// `if (!message) throw new BadRequest({ error: "Selected message does not exist!" })`.
  @discardableResult
  func requireMessage(_ guid: String) async throws -> IMessageRow {
    guard let row = try await repository.message(guid: guid) else {
      throw InterfaceError.invalidRequest(ReferenceMessages.selectedMessageMissing)
    }
    return row
  }

  /// Edits a message and answers with the edited row.
  ///
  /// The wait is different in kind from a send's. Nothing new appears — an existing row is
  /// MUTATED — so waiting for it to exist would return immediately with the message as it
  /// was before the edit, which is the pre-edit text a client would then display as though
  /// the edit had failed. What it waits for is `dateEdited` moving past what it was, which
  /// is exactly the reference's `extraLoopCondition`.
  public func edit(
    guid: String,
    partIndex: Int,
    newText: String,
    backwardCompatibilityText: String
  ) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "editing a message")
    // Message first, then its chat — the two refusals are different sentences in the
    // reference and this is the order that makes them mean what they say.
    //
    // Read BEFORE the edit. A message edited twice already has a `dateEdited`, so
    // "is it set" is not the question — "is it later than it was" is.
    let previousEdit = try await requireMessage(guid).dateEdited
    let chat = try await owningChat(of: guid)

    try await throughMessages {
      try await api.editMessage(
        MessageGUID(guid), in: chat, partIndex: partIndex,
        newText: newText, backwardCompatibilityText: backwardCompatibilityText
      )
    }
    return try await mutated(guid: guid, past: previousEdit)
  }

  /// The chat a message belongs to, from chat.db.
  ///
  /// The route carries only the message GUID, and the helper cannot fill the gap: an
  /// `IMMessageItem` fetched by GUID reports `chatIdentifier = nil`, so there is nothing on
  /// the message itself to resolve a conversation from. The database has the join, so the
  /// lookup belongs here.
  ///
  /// A message in more than one chat takes the first; that only happens for rows the
  /// database has duplicated, and either answer names the same conversation.
  private func owningChat(of messageGUID: String) async throws -> ChatIdentifier {
    let chats = try await repository.chats(forMessageGUID: messageGUID)
    guard let guid = chats.first?.guid else {
      // "Associated chat not found!", not "does not exist" — the reference reports the two
      // separately, and they mean different things to whoever is reading the error: a GUID
      // that names nothing, versus a message that is real and belongs to no conversation.
      // Callers check the message FIRST so this one only ever means the second.
      throw InterfaceError.invalidRequest(ReferenceMessages.associatedChatMissing)
    }
    return ChatIdentifier(guid)
  }

  /// Unsends a message and answers with the retracted row.
  ///
  /// Watches `dateEdited`, not `dateRetracted`, which looks like a mistake and is not: an
  /// unsend is recorded as an edit that empties the part, so `date_edited` is the column
  /// Messages moves. The reference watches the same one, and watching `dateRetracted`
  /// instead would wait out the full timeout on every successful unsend.
  public func unsend(guid: String, partIndex: Int) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "unsending a message")
    let previousEdit = try await requireMessage(guid).dateEdited
    let chat = try await owningChat(of: guid)

    try await throughMessages {
      try await api.unsendMessage(MessageGUID(guid), in: chat, partIndex: partIndex)
    }
    return try await mutated(guid: guid, past: previousEdit)
  }

  /// Rings a silenced message through, and answers with the notified row.
  ///
  /// Refused when the recipient has already been notified: the reference checks
  /// `didNotifyRecipient` before calling Messages, because the flag is what the wait below
  /// keys on — asking twice would leave it already true and answer instantly with a
  /// notification that never went out.
  public func notify(guid: String) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "notify anyway")
    let row = try await requireMessage(guid)
    guard row.didNotifyRecipient != true else {
      throw InterfaceError.invalidRequest(
        "The recipient has already been notified of this message!")
    }

    let chat = try await owningChat(of: guid)
    try await throughMessages {
      try await api.notifyAnyways(MessageGUID(guid), in: chat)
    }

    let notified = try await poll(policy: .mutation) {
      let projection = try await self.find(guid: guid, query: Self.sendQuery)
      return projection?.row.didNotifyRecipient == true ? projection : nil
    }
    return SendOutcome(backend: .privateAPI, messageGUID: guid, message: notified)
  }

  /// Waits for a row's `dateEdited` to move past what it was, then loads it.
  ///
  /// Nil on timeout, like a send's hydration and for the same reason: the edit was accepted
  /// by Messages, and answering 500 would tell a client its edit failed when it did not.
  func mutated(guid: String, past previous: AppleTimestamp?) async throws -> SendOutcome {
    // Compared as RAW values, with unset counting as zero — the reference's
    // `(data?.dateEdited ?? 0) <= currentEditDate`. Both readings come from the same
    // database in the same unit, so this is exact, and it sidesteps the fact that
    // `AppleTimestamp.date` is optional precisely because zero means "never" rather than
    // 2001-01-01.
    let before = previous?.rawValue ?? 0
    let edited = try await poll(policy: .mutation) {
      guard let projection = try await self.find(guid: guid, query: Self.sendQuery) else {
        return nil
      }
      return (projection.row.dateEdited?.rawValue ?? 0) > before ? projection : nil
    }
    return SendOutcome(backend: .privateAPI, messageGUID: guid, message: edited)
  }

  public func embeddedMediaPath(guid: String) async throws -> String {
    let api = try requirePrivateAPI(for: "embedded media")
    return try await throughMessages {
      try await api.balloonBundleMediaPath(for: MessageGUID(guid))
    }
  }
}
