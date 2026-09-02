//  ChatInterface
//  Chat operations, independent of how they were asked for.
//
//  See MessageInterface for why this layer exists.

import BBAppleScript
import BBCore
import BBIMessage
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import BBShortcuts
import Foundation
import Logging

public struct ChatInterface: MessagesBackedInterface {

  private let repository: MessageRepository
  private let serializer: MessageSerializer
  let privateAPI: (any PrivateAPI)?
  /// The one-to-one creation path. Not optional: it needs no install and no permission
  /// beyond the Automation grant sending already requires, so there is no configuration in
  /// which it is absent.
  private let appleScript: AppleScriptMessageSender
  /// The group creation path, when the user has set it up. Nil when the feature is not
  /// available at all — an app build without it, or a test that does not exercise it.
  private let shortcuts: GroupChatShortcutManager?
  /// Shared with the sender, so "the same address" means the same thing on both sides of a
  /// create-then-look-up round trip. Two formatters with different default regions would
  /// resolve `+1…` and a local number differently and the lookup would silently miss.
  private let addressFormatter: AddressFormatter
  let logger: Logger

  public init(
    repository: MessageRepository,
    serializer: MessageSerializer,
    privateAPI: (any PrivateAPI)? = nil,
    appleScript: AppleScriptMessageSender = AppleScriptMessageSender(),
    shortcuts: GroupChatShortcutManager? = nil,
    addressFormatter: AddressFormatter = .shared,
    logger: Logger = Logger(label: "bluebubbles.interface.chat")
  ) {
    self.repository = repository
    self.serializer = serializer
    self.privateAPI = privateAPI
    self.appleScript = appleScript
    self.shortcuts = shortcuts
    self.addressFormatter = addressFormatter
    self.logger = logger
  }

  // MARK: - Reading

  public struct Query: Sendable {
    public var limit: Int
    public var offset: Int
    public var includeArchived: Bool
    public var withParticipants: Bool
    public var withLastMessage: Bool
    public var sortByLastMessage: Bool

    public init(
      limit: Int = 1000,
      offset: Int = 0,
      includeArchived: Bool = true,
      withParticipants: Bool = true,
      withLastMessage: Bool = false,
      sortByLastMessage: Bool = false
    ) {
      self.limit = limit
      self.offset = offset
      self.includeArchived = includeArchived
      self.withParticipants = withParticipants
      self.withLastMessage = withLastMessage
      self.sortByLastMessage = sortByLastMessage
    }

    public static func parse(_ body: JSONValue) -> Query {
      let relations = (body["with"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        .map { $0.lowercased() }
      func wants(_ name: String) -> Bool { relations.contains { $0.contains(name) } }

      return Query(
        limit: body["limit"]?.intValue ?? 1000,
        offset: body["offset"]?.intValue ?? 0,
        // `false` only when explicitly asked; the default includes archived chats.
        includeArchived: body["includeArchived"]?.boolValue ?? true,
        withParticipants: relations.isEmpty ? true : wants("participant"),
        withLastMessage: wants("lastmessage"),
        sortByLastMessage: (body["sort"]?.stringValue ?? "").lowercased() == "lastmessage"
      )
    }
  }

  /// Just enough of a chat to offer it in a picker.
  ///
  /// Three fields against a whole `ChatRow`, and no last-message load. `query` already
  /// returns `ChatProjection` values and serializes nothing unless asked, so this exists for
  /// the narrowness alone.
  ///
  /// A caller that wants more should use `query` directly rather than growing this type —
  /// growing it is how this layer ends up with a second, parallel set of chat types.
  public struct ChatSummary: Sendable, Identifiable {
    public let guid: String
    public let displayName: String?
    /// The addresses the chat is with.
    public let participants: [String]
    public var id: String { guid }

    public init(guid: String, displayName: String?, participants: [String]) {
      self.guid = guid
      self.displayName = displayName
      self.participants = participants
    }
  }

  public func summaries(
    limit: Int = 500, sortByLastMessage: Bool = true
  ) async throws -> [ChatSummary] {
    let rows = try await repository.chats(
      includeArchived: true, limit: limit, offset: 0, sortByLastMessage: sortByLastMessage
    )
    var summaries: [ChatSummary] = []
    summaries.reserveCapacity(rows.count)
    for row in rows {
      summaries.append(
        ChatSummary(
          guid: row.guid,
          displayName: row.displayName,
          participants: try await repository.participants(chatGUID: row.guid).map(\.id)
        )
      )
    }
    return summaries
  }

  /// A chat together with what was loaded alongside it. See
  /// `MessageInterface.MessageProjection` for why this layer returns rows rather than JSON.
  public struct ChatProjection: Sendable {
    public let row: ChatRow
    /// Empty when the caller did not ask to LOAD them. The key is emitted on a top-level
    /// chat either way — see `serialize` — which is the reference's behaviour.
    public let participants: [HandleRow]
    /// The chat's most recent message, when it was asked for.
    public let lastMessage: MessageInterface.MessageProjection?
  }

  public func query(_ query: Query) async throws -> [ChatProjection] {
    let rows = try await repository.chats(
      includeArchived: query.includeArchived,
      limit: query.limit,
      offset: query.offset,
      sortByLastMessage: query.sortByLastMessage
    )
    return try await project(rows, query: query)
  }

  public func find(guid: String, query: Query = Query()) async throws -> ChatProjection? {
    guard let row = try await repository.chat(guid: guid) else { return nil }
    return try await project([row], query: query).first
  }

  /// Wire form, for the HTTP layer.
  public func serialize(_ projections: [ChatProjection]) -> [JSONValue] {
    projections.map { projection in
      var object = ChatSerializer.serialize(
        projection.row,
        participants: projection.participants,
        // Always emitted on a top-level chat, empty when nobody asked to LOAD them —
        // the reference serializes these with `DEFAULT_CHAT_CONFIG`, whose
        // `includeParticipants` is true regardless of the query. Only a chat nested
        // inside a message omits the key.
        includeParticipants: true
      )
      if let last = projection.lastMessage {
        object = object.merging([
          "lastMessage": serializer.serialize(
            last.row, context: last.relations, config: .full)
        ])
      }
      return object
    }
  }

  public func serialize(_ projection: ChatProjection) -> JSONValue {
    serialize([projection])[0]
  }

  public func count(includeArchived: Bool = true) async throws -> Int {
    try await repository.chatCount(includeArchived: includeArchived)
  }

  /// Chat totals per service — `iMessage`, `SMS`, `RCS` — and the sum.
  public struct ChatCounts: Sendable, Equatable {
    public let total: Int
    public let breakdown: [String: Int]

    public init(breakdown: [String: Int]) {
      self.breakdown = breakdown
      self.total = breakdown.values.reduce(0, +)
    }
  }

  /// Chats grouped by service, which is what `GET /api/v1/chat/count` reports.
  ///
  /// Chats with no participants are excluded, matching the reference, whose `getChats`
  /// inner-joins participants. Not a quirk being reproduced for parity's sake: there is
  /// nobody to send to in such a chat, so it is not something a client can act on. The
  /// listing and both counts share one definition of it so they cannot disagree.
  public func countByService(includeArchived: Bool = true) async throws -> ChatCounts {
    ChatCounts(
      breakdown: try await repository.chatCountsByService(includeArchived: includeArchived)
    )
  }

  /// `{total, breakdown: {<service>: n}}` — keyed by service NAME, not by chat style. A
  /// client reads `data.breakdown.iMessage`.
  public static func serialize(_ counts: ChatCounts) -> JSONValue {
    .object([
      "total": .int(counts.total),
      "breakdown": .object(counts.breakdown.mapValues(JSONValue.int)),
    ])
  }

  /// Messages in a chat. Delegates to the message repository rather than duplicating the
  /// query, so the two agree about what "in a chat" means — including the `any;-;` GUID
  /// tolerance, which is easy to get right in one place and easy to forget in two.
  public func messages(
    chatGUID: String,
    query: MessageInterface.Query
  ) async throws -> [MessageInterface.MessageProjection] {
    var scoped = query
    scoped.chatGUID = chatGUID
    return try await MessageInterface(
      repository: repository, serializer: serializer, privateAPI: privateAPI
    ).query(scoped)
  }

  /// Loads whatever the query asked for. Exactly what the old private `serialize` did,
  /// minus the final serializer calls.
  private func project(_ rows: [ChatRow], query: Query) async throws -> [ChatProjection] {
    var results: [ChatProjection] = []
    for row in rows {
      let participants =
        query.withParticipants
        ? try await repository.participants(chatGUID: row.guid)
        : []

      var lastMessage: MessageInterface.MessageProjection?
      if query.withLastMessage {
        let last = try await repository.messages(
          MessageRepository.MessageQuery(chatGUID: row.guid, limit: 1, ascending: false)
        ).first
        if let last {
          // Only the handle, as before: a nested last message carries neither its own
          // chats nor its attachments.
          var context = MessageSerializer.Context()
          if let handleID = last.handleID {
            context.handle = try await repository.handle(rowID: handleID)
          }
          lastMessage = MessageInterface.MessageProjection(row: last, relations: context)
        }
      }

      results.append(
        ChatProjection(row: row, participants: participants, lastMessage: lastMessage))
    }
    return results
  }

  // MARK: - Creating a chat

  /// Which backend created a chat, or would.
  ///
  /// Reported rather than discovered, for the same reason `MessageInterface.SendBackend`
  /// is: a user without the helper should be told what they have before they try, not meet
  /// a refusal at the moment they act.
  public enum CreateBackend: String, Sendable {
    case privateAPI = "private-api"
    /// One-to-one only. Nothing is explicitly created — sending to a participant with no
    /// conversation makes Messages open one.
    case appleScript = "apple-script"
    /// Groups, without the helper. See `BBShortcuts`.
    case shortcut
  }

  /// Creates a chat and returns its GUID.
  ///
  /// THREE BACKENDS, AND THE ORDER IS NOT NEGOTIABLE
  /// ----------------------------------------------
  /// 1. **The Private API**, when connected. It creates either kind, needs no first
  ///    message, and returns the GUID directly.
  /// 2. **AppleScript**, for a ONE-TO-ONE chat only. It cannot create anything explicitly —
  ///    `make new chat` has been a stub since Big Sur, three releases below this package's
  ///    floor — so the chat comes into existence as a side effect of sending to the
  ///    participant. That is why a first message is required without the helper.
  /// 3. **The Shortcut**, for a GROUP, and only if the user has installed it. There is no
  ///    other route: `is.workflow.actions.sendmessage` is the only messaging action on the
  ///    system, and AppleScript has no group path on any supported macOS.
  ///
  /// **Do not add an AppleScript attempt before the Shortcut for groups.** It cannot
  /// succeed on macOS 14, 15 or 26, and the failed round trip would be paid on every group
  /// a user creates. See `MessagesScripts` for the measurements.
  public func create(
    addresses: [String],
    service: String = "iMessage",
    message: String? = nil
  ) async throws -> String {
    guard !addresses.isEmpty else {
      throw InterfaceError.invalidRequest("at least one address is required")
    }

    if let privateAPI, await privateAPI.isConnected {
      let guid = try await throughMessages {
        try await privateAPI.createChat(
          addresses: addresses, service: service, message: message
        )
      }
      return guid.rawValue
    }

    // Everything below creates the chat BY SENDING, so there has to be something to send.
    // Stated as a 400 with the reason rather than a generic failure: the caller can fix it,
    // and the Private API genuinely does not need it, so "a message is required" alone
    // would read as a contradiction of the documented contract.
    guard let message, !message.isEmpty else {
      throw InterfaceError.invalidRequest(
        "a message is required when creating a chat without the Private API, because the "
          + "chat is created by sending the first message"
      )
    }

    let resolved = MessagingService(rawValue: service) ?? .iMessage
    if addresses.count == 1 {
      return try await createDirectChat(
        address: addresses[0], service: resolved, message: message
      )
    }
    return try await createGroupChat(
      addresses: addresses, service: resolved, message: message
    )
  }

  /// A one-to-one chat, opened by sending to the participant.
  private func createDirectChat(
    address: String, service: MessagingService, message: String
  ) async throws -> String {
    let formatted = try await throughMessages {
      try await appleScript.send(address: address, service: service, text: message)
    }
    // The send reports the address it used, not a GUID, so the chat is looked up the same
    // way the group path does it.
    //
    // The Node server INFERRED the GUID here instead — `${service};-;${address}` — and
    // returned it without checking. That is no longer safe: macOS 26 rewrote every chat
    // GUID prefix to the literal `any`, so the inferred spelling matches no row and a
    // client that stored it would address a chat the database does not have. Reading the
    // real GUID back costs one query and is correct on every version.
    //
    // The inferred form is still the fallback, so a database that has not caught up yet
    // returns what the Node server did rather than failing.
    // A short deadline, unlike the group path: this one has a correct answer to fall back
    // on, so waiting half a minute to avoid using it would be the wrong trade.
    if let guid = try await resolveChat(addresses: [formatted], waitFor: .seconds(5)) {
      return guid
    }
    return "\(service.rawValue);-;\(formatted)"
  }

  /// A group chat, through the user-installed Shortcut.
  private func createGroupChat(
    addresses: [String], service: MessagingService, message: String
  ) async throws -> String {
    guard let shortcuts, await shortcuts.isInstalled() else {
      throw InterfaceError.capabilityUnavailable(
        "Creating a group chat needs either the Private API or the BlueBubbles group chat "
          + "Shortcut. Install the Shortcut from Settings › General › Features.",
        feature: "creating a group chat"
      )
    }
    let formatted = addresses.map { addressFormatter.iMessageFormat($0) }
    try await throughMessages {
      try await shortcuts.send(recipients: formatted, message: message)
    }

    guard let guid = try await resolveChat(addresses: formatted, waitFor: .seconds(30)) else {
      // The send succeeded and the chat is not in the database yet, or Messages routed it
      // somewhere the participant set does not describe. Reported honestly rather than
      // returning a GUID we guessed: a client that stores a wrong one sends every later
      // message into the void.
      throw InterfaceError.messagesFailed(
        "The group chat Shortcut ran, but the new chat could not be found in the message "
          + "database. It may still appear in Messages."
      )
    }
    return guid
  }

  /// Finds the chat whose participants are exactly `addresses`, waiting for it to appear.
  ///
  /// POLLING IS NOT OPTIONAL HERE. The Shortcuts send action returns nothing at all — no
  /// GUID, no identifier, no output of any kind — so the only way to name the chat that was
  /// just created is to find it by its participants. `chat.db` is written by Messages after
  /// the send returns, so the row is reliably absent for the first moment.
  ///
  /// - Parameter waitFor: How long to keep looking. The group path uses the same deadline
  ///   the Node server used for its equivalent wait, because it has no fallback and a slow
  ///   Mac must still succeed. The direct path uses a much shorter one — it can infer a
  ///   correct GUID, so a long wait would buy nothing.
  private func resolveChat(
    addresses: [String], waitFor timeout: Duration
  ) async throws -> String? {
    let deadline = Date().addingTimeInterval(
      Double(timeout.components.seconds))
    let normalize: @Sendable (String) -> String = { [addressFormatter] in
      addressFormatter.iMessageFormat($0)
    }
    while true {
      let matches = try await repository.chats(
        matchingParticipants: addresses, normalize: normalize)
      if let newest = matches.first { return newest.guid }
      guard Date() < deadline else { return nil }
      try? await Task.sleep(for: .milliseconds(500))
    }
  }

  /// One chat's row, or a refusal naming the GUID.
  ///
  /// Distinct from `find(guid:query:)`, which builds a projection with its relations. The
  /// group-icon and background routes want the row itself and nothing loaded alongside it.
  public func row(guid: String) async throws -> ChatRow {
    guard let chat = try await repository.chat(guid: guid) else {
      throw InterfaceError.notFound("no chat with GUID \(guid)")
    }
    return chat
  }

  /// The group photo on disk, for a chat that has one.
  ///
  /// Reads Messages' own photo directory — no helper needed, which is why the route is scoped
  /// to `attachments:read` rather than requiring the Private API. Two distinct refusals: the
  /// chat does not exist, or it exists and has never had a photo set.
  public func groupIconPath(guid: String) async throws -> String {
    let chat = try await row(guid: guid)
    guard let path = GroupIconStore.path(forGroupID: chat.groupID) else {
      throw InterfaceError.notFound("that chat has no group photo")
    }
    return path
  }

  // MARK: - Private-API-only operations

  public func delete(guid: String) async throws {
    let api = try requirePrivateAPI(for: "deleting a chat")
    try await throughMessages { try await api.deleteChat(ChatIdentifier(guid)) }
  }

  public func leave(guid: String) async throws {
    let api = try requirePrivateAPI(for: "leaving a chat")
    try await throughMessages { try await api.leaveChat(ChatIdentifier(guid)) }
  }

  public func setPinned(guid: String, pinned: Bool) async throws {
    let api = try requirePrivateAPI(for: "pinning a chat")
    try await throughMessages {
      try await api.setPinned(chat: ChatIdentifier(guid), pinned: pinned)
    }
  }

  /// The pinned conversations, in display order, each serialized as a full chat.
  ///
  /// Full chats rather than bare GUIDs. A client syncing pins has to show them, and a list
  /// of GUIDs would mean a request per pin to render a name — on the one call whose entire
  /// purpose is "tell me the state so I can mirror it elsewhere".
  ///
  /// A GUID the helper reports that this database no longer has is DROPPED, not returned as
  /// a stub: it means Messages is holding a pin for a conversation that is gone, and a
  /// client cannot act on it.
  public func pinned(query: Query = Query()) async throws -> [ChatProjection] {
    let api = try requirePrivateAPI(for: "reading pinned chats")
    var rows: [ChatRow] = []
    for guid in try await throughMessages({ try await api.pinnedChats() }) {
      // One lookup per pin, and people pin a handful. Order is preserved by appending
      // in the order the helper gave, which IS the display order.
      if let row = try await repository.chats(guid: guid.rawValue).first {
        rows.append(row)
      }
    }
    return try await project(rows, query: query)
  }

  // MARK: Mute

  public func muteState(guid: String) async throws -> ChatMuteState {
    let api = try requirePrivateAPI(for: "reading a chat's mute state")
    return try await throughMessages { try await api.muteState(chat: ChatIdentifier(guid)) }
  }

  /// Mutes until `until`, or indefinitely when it is nil.
  ///
  /// The date arrives absolute. Every granularity a client offers — an hour, this evening,
  /// tomorrow, forever — is a date it computes, so the server never grows a menu of
  /// durations that has to be kept in step with someone's UI.
  public func setMute(
    guid: String, until: Date?, syncToPairedDevice: Bool
  ) async throws -> ChatMuteState {
    let api = try requirePrivateAPI(for: "muting a chat")
    // A mute that has already expired is a no-op reported as a success. The helper
    // refuses it too, but a rejection from Messages surfaces as a 500 — and this is a
    // client mistake, which is a 400. Both checks stay: one is the API's contract, the
    // other is the last line before IMCore.
    if let until, until <= Date() {
      throw InterfaceError.invalidRequest(
        "`mutedUntil` is in the past; send a future date, `durationSeconds`, or "
          + "`indefinite: true`"
      )
    }
    return try await throughMessages {
      try await api.setMute(
        ChatMuteRequest(
          chat: ChatIdentifier(guid), until: until, syncToPairedDevice: syncToPairedDevice
        )
      )
    }
  }

  public func unmute(guid: String, syncToPairedDevice: Bool) async throws -> ChatMuteState {
    let api = try requirePrivateAPI(for: "unmuting a chat")
    return try await throughMessages {
      try await api.unmute(
        chat: ChatIdentifier(guid), syncToPairedDevice: syncToPairedDevice
      )
    }
  }

  /// Asks Messages to download this conversation's background asset from iCloud.
  public func refetchBackground(guid: String) async throws {
    let api = try requirePrivateAPI(for: "downloading a chat background")
    try await throughMessages { try await api.refetchChatBackground(chat: ChatIdentifier(guid)) }
  }

  // MARK: History and filtering

  /// Deletes every message in a conversation. The conversation itself stays.
  ///
  /// Destructive and synced — the messages leave every device on the account. The
  /// confirmation and the user-visible alert live in the handler; this layer does the work.
  public func clearHistory(guid: String) async throws -> Bool {
    let api = try requirePrivateAPI(for: "clearing a chat's history")
    return try await throughMessages { try await api.clearChatHistory(ChatIdentifier(guid)) }
  }

  public func filterState(guid: String) async throws -> ChatFilterState {
    let api = try requirePrivateAPI(for: "reading a chat's filter state")
    return try await throughMessages { try await api.chatFilterState(chat: ChatIdentifier(guid)) }
  }

  public func markSenderKnown(
    guid: String, saveInContacts: Bool
  ) async throws -> ChatFilterState {
    let api = try requirePrivateAPI(for: "marking a sender as known")
    return try await throughMessages {
      try await api.markSenderKnown(chat: ChatIdentifier(guid), saveInContacts: saveInContacts)
    }
  }

  public func markSpam(
    guid: String, reportToCarrier: Bool, dryRun: Bool
  ) async throws -> ChatSpamResult {
    let api = try requirePrivateAPI(for: "marking a chat as spam")
    return try await throughMessages {
      try await api.markChatAsSpam(
        ChatSpamRequest(
          chat: ChatIdentifier(guid), reportToCarrier: reportToCarrier, dryRun: dryRun
        )
      )
    }
  }

  public func reportJunk(
    guid: String, reportToCarrier: Bool, dryRun: Bool
  ) async throws -> ChatSpamResult {
    let api = try requirePrivateAPI(for: "reporting a chat as junk")
    return try await throughMessages {
      try await api.reportChatAsJunk(
        ChatSpamRequest(
          chat: ChatIdentifier(guid), reportToCarrier: reportToCarrier, dryRun: dryRun
        )
      )
    }
  }

  public func setFilter(guid: String, category: Int) async throws -> ChatFilterState {
    let api = try requirePrivateAPI(for: "changing a chat's filter")
    guard category >= 0 else {
      throw InterfaceError.invalidRequest("`category` must be zero or greater")
    }
    return try await throughMessages {
      try await api.setChatFilter(chat: ChatIdentifier(guid), category: category)
    }
  }

  public static func serialize(_ state: ChatFilterState) -> JSONValue {
    .object([
      "is_filtered": .int(state.isFiltered),
      "filter_category": .int(state.filterCategory),
      "is_known_sender": .bool(state.isKnownSender),
      "is_in_unknown_senders_filter": .bool(state.isInUnknownSendersFilter),
      "was_detected_as_sms_spam": .bool(state.wasDetectedAsSMSSpam),
      "can_report_junk": .bool(state.canReportJunk),
    ])
  }

  public static func serialize(_ result: ChatSpamResult) -> JSONValue {
    .object([
      "message_count": .int(result.messageCount),
      "reported_to_carrier": .bool(result.reportedToCarrier),
      "dry_run": .bool(result.wasDryRun),
      "filter": serialize(result.filter),
    ])
  }

  /// The mute state as JSON. Epoch milliseconds, per the serializer convention — this is
  /// not a TypeORM entity, so `WireDate.iso` does not apply.
  public static func serialize(_ state: ChatMuteState) -> JSONValue {
    .object([
      "is_muted": .bool(state.isMuted),
      "is_indefinite": .bool(state.isIndefinite),
      "muted_until": state.mutedUntil
        .map { JSONValue.int64(Int64(($0.timeIntervalSince1970 * 1000).rounded())) }
        ?? .null,
    ])
  }

  public func setDisplayName(guid: String, to name: String) async throws {
    let api = try requirePrivateAPI(for: "renaming a chat")
    try await throughMessages { try await api.setDisplayName(chat: ChatIdentifier(guid), to: name) }
  }

  public func setGroupPhoto(guid: String, imagePath: String) async throws {
    let api = try requirePrivateAPI(for: "setting a group photo")
    guard FileManager.default.fileExists(atPath: imagePath) else {
      throw InterfaceError.invalidRequest("no file at \(imagePath)")
    }
    try await throughMessages {
      try await api.updateGroupPhoto(chat: ChatIdentifier(guid), imagePath: imagePath)
    }
  }

  public func addParticipant(_ address: String, to guid: String) async throws {
    let api = try requirePrivateAPI(for: "adding a participant")
    try await throughMessages { try await api.addParticipant(address, to: ChatIdentifier(guid)) }
  }

  public func removeParticipant(_ address: String, from guid: String) async throws {
    let api = try requirePrivateAPI(for: "removing a participant")
    try await throughMessages {
      try await api.removeParticipant(address, from: ChatIdentifier(guid))
    }
  }

  public func setTyping(guid: String, typing: Bool) async throws {
    let api = try requirePrivateAPI(for: "typing indicators")
    try await throughMessages {
      if typing {
        try await api.startTyping(chat: ChatIdentifier(guid))
      } else {
        try await api.stopTyping(chat: ChatIdentifier(guid))
      }
    }
  }

  public func markRead(guid: String) async throws {
    let api = try requirePrivateAPI(for: "marking a chat read")
    try await throughMessages { try await api.markRead(chat: ChatIdentifier(guid)) }
  }

  public func markUnread(guid: String) async throws {
    let api = try requirePrivateAPI(for: "marking a chat unread")
    try await throughMessages { try await api.markUnread(chat: ChatIdentifier(guid)) }
  }

  public func deleteMessage(_ messageGUID: String, in chatGUID: String) async throws {
    let api = try requirePrivateAPI(for: "deleting a message")
    try await throughMessages {
      try await api.deleteMessage(MessageGUID(messageGUID), in: ChatIdentifier(chatGUID))
    }
  }
}
