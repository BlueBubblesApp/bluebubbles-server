//  MessageInterface
//  Message operations, independent of how they were asked for.
//
//  This is the layer the plan calls for: controllers stay thin and delegate here, and the
//  same methods serve the HTTP routes, the legacy socket commands, and the SwiftUI app. That
//  is what makes the current implementation's **68 IPC channels** unnecessary — they exist
//  because the UI cannot reach the business logic any other way, so every operation needs a
//  hand-written channel on both sides.
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
    /// unless asked for — the current server loads participants unconditionally, which is
    /// where its chat listing spends most of its time.
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
  /// version; the current server does the same and it is not the bottleneck at these page
  /// sizes. If it becomes one, the fix is a batched fetch here — which is possible
  /// precisely because it is one function rather than fifteen call sites.
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
      }
      results.append(MessageProjection(row: row, relations: context))
    }
    return results
  }

  /// The messages behind a set of GUIDs, ready to send.
  ///
  /// For the hydration route: a client holding notification payloads asks for the full
  /// messages behind them. Deduplicated, because a message in several chats produces several
  /// notifications and the client should not pay for the same lookup twice.
  ///
  /// A GUID that no longer resolves is OMITTED rather than erroring the batch. A message
  /// deleted between the notification and the hydration is normal, and failing the whole
  /// request would lose the eleven that were fine.
  ///
  /// Returns serialized values rather than rows, which is the exception to this layer's usual
  /// rule and is deliberate: the config is fixed by the route rather than chosen by the caller,
  /// so handing back projections would oblige every caller to re-derive the same `.full`. See
  /// `ServerInterface.backups` for the same shape and the same reason.
  public func hydrate(guids: [String]) async throws -> [JSONValue] {
    var seen = Set<String>()
    var results: [JSONValue] = []
    for guid in guids where seen.insert(guid).inserted {
      guard let row = try await repository.message(guid: guid) else { continue }
      results.append(
        serializer.serialize(row, context: MessageSerializer.Context(), config: .full)
      )
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

  public struct SendTextRequest: Sendable {
    public var chatGUID: String
    public var text: String
    public var subject: String?
    public var effectID: String?
    public var replyToGUID: String?
    public var partIndex: Int
    public var scanForLinks: Bool
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
      forcedBackend: SendBackend? = nil
    ) {
      self.chatGUID = chatGUID
      self.text = text
      self.subject = subject
      self.effectID = effectID
      self.replyToGUID = replyToGUID
      self.partIndex = partIndex
      self.scanForLinks = scanForLinks
      self.forcedBackend = forcedBackend
    }
  }

  /// Sends a text message through whichever backend is available.
  ///
  /// The Private API is preferred when connected because it supports subjects, effects and
  /// replies; AppleScript supports none of those. When a request asks for a feature the
  /// chosen backend cannot deliver, that is reported rather than silently dropped — a reply
  /// that arrives as an ordinary message looks like the server ignored the user.
  public func sendText(_ request: SendTextRequest) async throws -> JSONValue {
    let backend: SendBackend
    if let forced = request.forcedBackend {
      backend = forced
    } else {
      backend = await availableBackend()
    }

    switch backend {
    case .privateAPI:
      guard let privateAPI else {
        throw InterfaceError.unavailable("the Private API is not available")
      }
      let sent = try await throughMessages {
        try await privateAPI.sendMessage(
          SendMessageRequest(
            chat: ChatGUID(request.chatGUID),
            text: request.text,
            subject: request.subject,
            effectId: request.effectID,
            replyTo: request.replyToGUID.map { MessageGUID($0) },
            replyPartIndex: request.partIndex,
            scanForLinks: request.scanForLinks
          )
        )
      }
      return .object([
        "guid": .string(sent.guid.rawValue),
        "backend": .string(backend.rawValue),
      ])

    case .appleScript:
      // Stated rather than dropped. A client that asked for a reply and got a plain
      // message would look like the server ignored it.
      if request.subject != nil || request.effectID != nil || request.replyToGUID != nil {
        throw InterfaceError.invalidRequest(
          "subjects, effects and replies need the Private API; this server is "
            + "sending through AppleScript"
        )
      }
      let resolved = try await throughMessages {
        try await appleScript.send(chatGUID: request.chatGUID, text: request.text)
      }
      return .object([
        "chatGuid": .string(resolved),
        "backend": .string(backend.rawValue),
      ])
    }
  }

  public func sendAttachment(
    chatGUID: String,
    filePath: String,
    isAudioMessage: Bool = false
  ) async throws -> JSONValue {
    let backend = await availableBackend()
    guard FileManager.default.fileExists(atPath: filePath) else {
      throw InterfaceError.invalidRequest("no file at \(filePath)")
    }

    switch backend {
    case .privateAPI:
      guard let privateAPI else {
        throw InterfaceError.unavailable("the Private API is not available")
      }
      let sent = try await throughMessages {
        try await privateAPI.sendAttachment(
          SendAttachmentRequest(
            chat: ChatGUID(chatGUID),
            // Messages cannot read outside its container; see AttachmentStaging.
            filePath: try AttachmentStaging.stage(filePath),
            isAudioMessage: isAudioMessage
          )
        )
      }
      return .object(["guid": .string(sent.guid.rawValue)])

    case .appleScript:
      let resolved = try await throughMessages {
        try await appleScript.send(chatGUID: chatGUID, attachmentPath: filePath)
      }
      return .object(["chatGuid": .string(resolved)])
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
  ) async throws -> JSONValue {
    let api = try requirePrivateAPI(for: "multipart messages")
    guard !parts.isEmpty else {
      throw InterfaceError.invalidRequest("at least one part is required")
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
          chat: ChatGUID(chatGUID),
          parts: try AttachmentStaging.stage(parts: parts),
          subject: subject,
          effectId: effectID,
          replyTo: replyToGUID.map { MessageGUID($0) },
          replyPartIndex: partIndex
        )
      )
    }
    return .object(["guid": .string(sent.guid.rawValue)])
  }

  // MARK: - Private-API-only operations
  //
  // Each of these throws `unavailableWithoutPrivateAPI` rather than a generic failure, so a
  // client can tell "this needs a feature you do not have" from "this went wrong".

  public func react(
    chatGUID: String,
    targetGUID: String,
    reaction: String,
    partIndex: Int = 0
  ) async throws {
    let api = try requirePrivateAPI(for: "reactions")
    guard let type = ReactionType(rawValue: reaction) else {
      throw InterfaceError.invalidRequest("unknown reaction type: \(reaction)")
    }
    try await throughMessages {
      try await api.react(
        ReactionRequest(
          chat: ChatGUID(chatGUID),
          target: MessageGUID(targetGUID),
          reaction: type,
          partIndex: partIndex
        )
      )
    }
  }

  public func edit(
    guid: String,
    partIndex: Int,
    newText: String,
    backwardCompatibilityText: String
  ) async throws {
    let api = try requirePrivateAPI(for: "editing a message")
    try await throughMessages {
      try await api.editMessage(
        MessageGUID(guid),
        in: try await owningChat(of: guid),
        partIndex: partIndex,
        newText: newText,
        backwardCompatibilityText: backwardCompatibilityText
      )
    }
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
  private func owningChat(of messageGUID: String) async throws -> BBPrivateAPIContract.ChatGUID {
    let chats = try await repository.chats(forMessageGUID: messageGUID)
    guard let guid = chats.first?.guid else {
      throw InterfaceError.invalidRequest("no message with GUID \(messageGUID)")
    }
    return BBPrivateAPIContract.ChatGUID(guid)
  }

  public func unsend(guid: String, partIndex: Int) async throws {
    let api = try requirePrivateAPI(for: "unsending a message")
    try await throughMessages {
      try await api.unsendMessage(
        MessageGUID(guid), in: try await owningChat(of: guid), partIndex: partIndex
      )
    }
  }

  public func notify(guid: String) async throws {
    let api = try requirePrivateAPI(for: "notify anyway")
    try await throughMessages {
      try await api.notifyAnyways(MessageGUID(guid))
    }
  }

  public func embeddedMediaPath(guid: String) async throws -> String {
    let api = try requirePrivateAPI(for: "embedded media")
    return try await throughMessages {
      try await api.balloonBundleMediaPath(for: MessageGUID(guid))
    }
  }
}
