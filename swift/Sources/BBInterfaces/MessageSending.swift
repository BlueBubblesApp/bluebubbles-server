//  MessageSending
//  Sending a message, and waiting for the row Messages writes.
//
//  An extension rather than a separate type, so nothing about the API changes: callers still
//  reach every one of these through `MessageInterface`. The split is about the FILE, which had
//  grown past 1,200 lines covering reading, projection, serialization, four send paths, send
//  hydration, scheduled messages and message mutation — seven jobs whose only relationship was
//  the type they hang off.
//
//  What is here is one job: turning a send request into a `SendOutcome`, including the wait
//  for the row. `MessageInterface.swift` keeps the type and the read path;
//  `MessageMutation.swift` has the operations that change a message after it exists.
//
//  See `.claude/docs/imessage.md` for the backend-by-backend table this implements.

import BBIMessage
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import Foundation

extension MessageInterface {
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
  /// 250 ms, then ×1.5, to a 60-second ceiling. Two of those three come from
  /// `resultAwaiter`'s defaults (`server/helpers/utils.ts:456` — `initialWaitMs = 250`,
  /// `waitMultiplier = 1.5`); the ceiling does NOT. `resultAwaiter` defaults `maxWaitMs` to
  /// 30_000, and the reference's send path overrides it to 60_000 explicitly
  /// (`messageInterface.ts:285`, `const maxWaitMs = 60000`) — which is why `mutation` below
  /// is thirty and this is sixty. An earlier version of this comment called all three
  /// "the defaults", which would have made a change to the ceiling look like a no-op.
  ///
  /// Kept because the thing being waited on is the same and its timing is Apple's. The
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
    /// send gets sixty — these call `resultAwaiter` without overriding `maxWaitMs`, so they
    /// get its 30_000 default. Transcribed rather than unified — the wait is for a column to move
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
  /// Not `private`, for the reason given in `MessageInterface.swift`: the mutation
  /// operations in `MessageMutation.swift` wait on the same poller.
  func poll(
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

  // MARK: - What a send is asked for
  //
  // One request type per send, all three nested here and all three carrying the same five
  // fields for the association a send can have: `chatGUID`, `subject`, `effectID`,
  // `replyToGUID`, `partIndex`. They were a request struct, seven loose parameters and six
  // loose parameters respectively — the same operation family in three calling conventions,
  // with the validation most tangled in the loose ones.
  //
  // `partIndex` is `Int` on text and `Int?` on the other two, and that is NOT drift to
  // tidy. The contract's `replyPartIndex` is `Int?`, so a text send always sends a value
  // (0 unless asked otherwise) while an attachment or multipart send omits it entirely.
  // Whether the helper distinguishes nil from 0 is its business; making them agree here
  // would change what goes over the wire on one of the two.

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
    /// "Send Later": when Messages should deliver this. Nil sends now.
    public var scheduledFor: Date?
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
      scheduledFor: Date? = nil,
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
      self.scheduledFor = scheduledFor
      self.forcedBackend = forcedBackend
    }
  }

  public struct SendAttachmentRequest: Sendable {
    public var chatGUID: String
    public var filePath: String
    /// A voice memo. Its own composition in Messages, which is why it cannot carry a
    /// subject, an effect or a reply — see `sendAttachment`.
    public var isAudioMessage: Bool
    public var subject: String?
    public var effectID: String?
    public var replyToGUID: String?
    public var partIndex: Int?

    public init(
      chatGUID: String,
      filePath: String,
      isAudioMessage: Bool = false,
      subject: String? = nil,
      effectID: String? = nil,
      replyToGUID: String? = nil,
      partIndex: Int? = nil
    ) {
      self.chatGUID = chatGUID
      self.filePath = filePath
      self.isAudioMessage = isAudioMessage
      self.subject = subject
      self.effectID = effectID
      self.replyToGUID = replyToGUID
      self.partIndex = partIndex
    }

    /// The multipart send this becomes when it carries an association.
    ///
    /// The helper's single-file action has no field for a subject, an effect or a reply, so
    /// a send that names one goes through the multipart action as a one-part message — same
    /// file, same row, with the association the client asked for. Written here rather than
    /// inline so the two requests cannot disagree about what carries over.
    var asMultipart: SendMultipartRequest {
      SendMultipartRequest(
        chatGUID: chatGUID,
        parts: [MessagePart(attachmentPath: filePath)],
        subject: subject,
        effectID: effectID,
        replyToGUID: replyToGUID,
        partIndex: partIndex
      )
    }

    /// Whether this names something the single-file action cannot carry.
    var needsMultipart: Bool {
      subject != nil || effectID != nil || replyToGUID != nil
    }
  }

  public struct SendMultipartRequest: Sendable {
    public var chatGUID: String
    /// In the order they arrive, and that order is the point of the route: mention indices
    /// are positional, so a dropped part renumbers every part after it.
    public var parts: [MessagePart]
    public var subject: String?
    public var effectID: String?
    public var replyToGUID: String?
    public var partIndex: Int?

    public init(
      chatGUID: String,
      parts: [MessagePart],
      subject: String? = nil,
      effectID: String? = nil,
      replyToGUID: String? = nil,
      partIndex: Int? = nil
    ) {
      self.chatGUID = chatGUID
      self.parts = parts
      self.subject = subject
      self.effectID = effectID
      self.replyToGUID = replyToGUID
      self.partIndex = partIndex
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
    if let scheduledFor = request.scheduledFor {
      try Self.checkScheduledSend(scheduledFor)
    }

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
            formatting: request.formatting,
            scheduledFor: request.scheduledFor
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
        || !request.formatting.isEmpty || request.scheduledFor != nil
      {
        throw InterfaceError.invalidRequest(
          "subjects, effects, replies, text formatting and Send Later need the Private "
            + "API; this server is sending through AppleScript"
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
  public func sendAttachment(_ request: SendAttachmentRequest) async throws -> SendOutcome {
    let backend = await availableBackend()
    let chatGUID = request.chatGUID
    let filePath = request.filePath
    guard FileManager.default.fileExists(atPath: filePath) else {
      throw InterfaceError.invalidRequest("no file at \(filePath)")
    }

    if request.needsMultipart {
      guard !request.isAudioMessage else {
        throw InterfaceError.invalidRequest(
          "a voice memo cannot carry a subject, an effect or a reply"
        )
      }
      return try await sendMultipart(request.asMultipart)
    }

    switch backend {
    case .privateAPI:
      guard let privateAPI else {
        throw InterfaceError.unavailable("the Private API is not available")
      }
      let sent = try await throughMessages {
        // Qualified: the nested `SendAttachmentRequest` above shadows the contract's
        // inside this type, and they are different shapes — one is what a caller asks
        // for, the other is what goes to the helper.
        try await privateAPI.sendAttachment(
          BBPrivateAPIContract.SendAttachmentRequest(
            chat: ChatIdentifier(chatGUID),
            // Messages cannot read outside its container; see AttachmentStaging.
            filePath: try AttachmentStaging.stage(filePath),
            isAudioMessage: request.isAudioMessage
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
  public func sendMultipart(_ request: SendMultipartRequest) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "multipart messages")
    let parts = request.parts
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
      // Qualified for the same reason as `sendAttachment` above.
      try await api.sendMultipart(
        BBPrivateAPIContract.SendMultipartRequest(
          chat: ChatIdentifier(request.chatGUID),
          parts: try AttachmentStaging.stage(parts: parts),
          subject: request.subject,
          effectId: request.effectID,
          replyTo: request.replyToGUID.map { MessageGUID($0) },
          replyPartIndex: request.partIndex
        )
      )
    }
    return SendOutcome(
      backend: .privateAPI,
      messageGUID: sent.guid.rawValue,
      message: try await awaitSentMessage(guid: sent.guid.rawValue)
    )
  }
}
