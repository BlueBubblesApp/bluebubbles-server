//  ChatInterface+Reading
//  Reading chats: querying them, counting them, and projecting rows into what a client sees.
//
//  Split from `ChatInterface` because the type had grown to 43 methods across four unrelated
//  concerns in one 718-line file. The type, its stored dependencies and its query vocabulary
//  are in `ChatInterface.swift`; this is everything that only reads.

import BBAppleScript
import BBCore
import BBIMessage
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import BBShortcuts
import Foundation
import Logging

extension ChatInterface {

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
    /// chat either way (see `serialize`) which is the reference's behaviour.
    public let participants: [HandleRow]
    /// The chat's most recent message, when it was asked for.
    public let lastMessage: MessageInterface.MessageProjection?
    /// Whether the caller ASKED for the last message, which is a different question from
    /// whether there was one.
    ///
    /// Both keys the reference emits for `with=lastMessage` depend on the request rather
    /// than on the row: `lastMessage` is set to `null` for a chat that has no messages, and
    /// `messages` is set to `[]` because the reference passes `includeMessages:
    /// withLastMessage` to its chat serializer. Deriving either from `lastMessage != nil`
    /// would drop the key from exactly the chats a client is most likely to mishandle: the
    /// empty ones.
    public let wantsLastMessage: Bool
  }

  public func query(_ query: Query) async throws -> [ChatProjection] {
    let rows = try await repository.chats(
      guid: query.guid,
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
        // Always emitted on a top-level chat, empty when nobody asked to LOAD them:
        // the reference serializes these with `DEFAULT_CHAT_CONFIG`, whose
        // `includeParticipants` is true regardless of the query. Only a chat nested
        // inside a message omits the key.
        includeParticipants: true,
        // `[]`, always, and only when the last message was asked for. The reference
        // passes `config: { includeMessages: withLastMessage }` and then serialises a
        // chat it deliberately loaded WITHOUT messages, so the key is present and empty.
        // It reads like an oversight there and is one clients have parsed for years.
        // `nil` (the key absent) is the other case, and `serialize(_ created:tempGUID:)`
        // is the third: a chat that really does carry a message.
        messages: projection.wantsLastMessage ? [] : nil
      )
      if projection.wantsLastMessage {
        object = object.merging([
          "lastMessage": projection.lastMessage.map {
            serializer.serialize($0.row, context: $0.relations, config: .full)
          } ?? .null
        ])
      }
      return object
    }
  }

  public func serialize(_ projection: ChatProjection) -> JSONValue {
    serialize([projection])[0]
  }

  /// The wire form of a create: the chat, the message it sent, and the client's `tempGuid`
  /// echoed onto that message.
  ///
  /// `messages` is emitted whether or not there is one, because the reference serializes
  /// this route with `includeMessages: true` and a client reads `data.messages`. It holds at
  /// most one element: `chatInterface.ts` assigns `chat.messages = [sentMessage]`, never
  /// more.
  public func serialize(_ created: CreatedChat, tempGUID: String? = nil) -> JSONValue {
    var messages: [JSONValue] = []
    if let sent = created.firstMessage {
      var message = serializer.serialize(
        sent.row, context: sent.relations,
        // NOT `.full`. The reference's `ChatSerializer` overrides `includeChats: false` on
        // the message config and leaves everything else at `DEFAULT_MESSAGE_CONFIG`, so the
        // three blob columns are not parsed for a nested message. Measured against the
        // recorded fixture: its `messages[0]` carries `attributedBody: null` and
        // `messageSummaryInfo: null` where the same send on `POST /message/text` — which
        // does use `.full` — has both decoded.
        config: MessageSerializerConfig(includeChats: false)
      )
      if let tempGUID {
        // Merged after serialising, not passed in: `tempGuid` is the client's own
        // correlation token echoed back, not a column. Same shape as the send routes, and
        // `chatRouter.create` writes it onto each element of `data.messages` for the same
        // reason — it is how a client matches the bubble it drew optimistically to the row
        // Messages wrote.
        message = message.merging(["tempGuid": .string(tempGUID)])
      }
      messages.append(message)
    }
    return ChatSerializer.serialize(
      created.projection.row,
      participants: created.projection.participants,
      includeParticipants: true,
      messages: messages
    )
  }

  public func count(includeArchived: Bool = true) async throws -> Int {
    try await repository.chatCount(includeArchived: includeArchived)
  }

  /// Chat totals per service (`iMessage`, `SMS`, `RCS`) and the sum.
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

  /// `{total, breakdown: {<service>: n}}`: keyed by service NAME, not by chat style. A
  /// client reads `data.breakdown.iMessage`.
  public static func serialize(_ counts: ChatCounts) -> JSONValue {
    .object([
      "total": .int(counts.total),
      "breakdown": .object(counts.breakdown.mapValues(JSONValue.int)),
    ])
  }

  /// Messages in a chat. Delegates to the message repository rather than duplicating the
  /// query, so the two agree about what "in a chat" means, including the `any;-;` GUID
  /// tolerance, which is easy to get right in one place and easy to forget in two.
  public func messages(
    chatGUID: String,
    query: MessageInterface.Query
  ) async throws -> [MessageInterface.MessageProjection] {
    var scoped = query
    scoped.chatGUID = chatGUID
    // No helper passed: `query` is a pure chat.db read; it goes to the repository and then
    // to `project`, neither of which touches Messages. Handing one over would imply a
    // dependency this call does not have.
    return try await MessageInterface(
      repository: repository, serializer: serializer
    ).query(scoped)
  }

  /// Loads whatever the query asked for, leaving the serializer calls to the caller.
  func project(_ rows: [ChatRow], query: Query) async throws -> [ChatProjection] {
    // The last message is one query per chat and stays that way: "the newest row in each
    // group" is not something one statement answers cheaply, and with the transcript's
    // ordering fixed each of these is an index seek rather than a sort of the conversation.
    //
    // Its SENDER is a different matter. That was a second query per chat -- 486 of them on
    // this database, to look up at most 486 handles -- and one `IN (...)` answers them all.
    // TWO queries for the whole list, not two per chat. The per-chat SQL is right -- each
    // lookup is a covering-index seek, and all of them together are about a millisecond --
    // but going through `messages()` once per chat cost statement preparation, row mapping
    // and an actor hop apiece: 165ms for this list, against 5ms batched.
    var lastByChatGUID: [String: IMessageRow] = [:]
    if query.withLastMessage {
      let byChatRowID = try await repository.lastMessages(forChatRowIDs: rows.map(\.rowID))
      for row in rows {
        if let last = byChatRowID[row.rowID] { lastByChatGUID[row.guid] = last }
      }
    }
    let handlesByRowID = try await repository.handles(
      rowIDs: lastByChatGUID.values.compactMap(\.handleID))

    var results: [ChatProjection] = []
    for row in rows {
      let participants =
        query.withParticipants
        ? try await repository.participants(chatGUID: row.guid)
        : []

      var lastMessage: MessageInterface.MessageProjection?
      if let last = lastByChatGUID[row.guid] {
        // Only the handle, as before: a nested last message carries neither its own
        // chats nor its attachments.
        var context = MessageSerializer.Context()
        if let handleID = last.handleID {
          context.handle = handlesByRowID[handleID]
        }
        lastMessage = MessageInterface.MessageProjection(row: last, relations: context)
      }

      results.append(
        ChatProjection(
          row: row, participants: participants, lastMessage: lastMessage,
          wantsLastMessage: query.withLastMessage))
    }
    return results
  }
}
