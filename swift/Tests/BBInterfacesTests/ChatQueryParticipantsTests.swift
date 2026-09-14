//  ChatQueryParticipantsTests
//  `POST /chat/query` returns participants, whatever else the caller asked for.
//
//  THE BUG THIS EXISTS TO PREVENT
//  The app's full sync asks for `{"with": ["lastMessage"]}` and then reads
//  `chat.handles` to decide whether a chat is real. `full_sync_manager.dart`:
//
//      if (chat.handles.isEmpty) {
//        addToOutput('Deleting chat: $displayName (no participants were found)');
//        ChatsSvc.softDeleteChat(chat);
//
//  So a `participants: []` is not a thinner response, it is a DELETE. A fresh sync against a
//  server that omitted them reported "no chats to sync" and soft-deleted every conversation
//  it had just been given.
//
//  `Query.parse` used to read `relations.isEmpty ? true : wants("participant")`: participants
//  by default, but only while `with` was EMPTY. The moment a client asked for anything at all
//  — `lastMessage`, which is what every full sync sends — the default inverted and
//  participants were dropped.
//
//  The reference never consults `with` for participants on this route.
//  `chatRouter.query` (`routers/chatRouter.ts:118`) reads `with` for `lastmessage` alone and
//  calls `ChatInterface.get`, which calls `getChats` WITHOUT `withParticipants`
//  (`interfaces/chatInterface.ts:37`), taking that function's default of `true`
//  (`databases/imessage/index.ts:68`). It then serializes under `DEFAULT_CHAT_CONFIG`, whose
//  `includeParticipants` is also true. Participants are unconditional there, in both the load
//  and the projection.
//
//  `GET /chat/:guid` is the one that gates them on `with`, and that asymmetry is real: see
//  the note on `.chatFind` in `ReadHandlers`. This suite pins the pair so a future tidy-up
//  cannot "make them consistent" and reintroduce the delete.

import BBSerialization
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Chat query participants")
struct ChatQueryParticipantsTests {

  private func parse(_ json: String) throws -> ChatInterface.Query {
    ChatInterface.Query.parse(try JSONValue.parse(Data(json.utf8)))
  }

  @Test("The full sync's own request still loads participants")
  func fullSyncRequestLoadsParticipants() throws {
    // Verbatim from `full_sync_manager.dart:streamChatPages`.
    let query = try parse(#"{"offset": 0, "limit": 200, "with": ["lastMessage"]}"#)
    #expect(
      query.withParticipants,
      "the full sync asks for lastMessage and deletes every chat that comes back without participants"
    )
    #expect(query.withLastMessage)
  }

  @Test("Participants survive any `with` a client sends")
  func participantsAreUnconditional() throws {
    for with in [
      #"[]"#,
      #"["lastMessage"]"#,
      #"["last-message"]"#,
      #"["participants"]"#,
      #"["lastMessage", "participants"]"#,
      #"["sms"]"#,
      #"["something-we-have-never-heard-of"]"#,
    ] {
      let query = try parse(#"{"with": \#(with)}"#)
      #expect(query.withParticipants, "with: \(with) must still carry participants")
    }
  }

  @Test("An absent `with` loads them too")
  func absentWithLoadsParticipants() throws {
    #expect(try parse(#"{}"#).withParticipants)
    #expect(try parse(#"{"limit": 200}"#).withParticipants)
  }

  @Test("`with` still decides the last message, which is what it is actually for")
  func withStillDrivesLastMessage() throws {
    #expect(!(try parse(#"{"with": []}"#).withLastMessage))
    #expect(try parse(#"{"with": ["lastMessage"]}"#).withLastMessage)
    #expect(try parse(#"{"with": ["last-message"]}"#).withLastMessage)
    // And the forced sort that comes with it, which the reference does in two places.
    #expect(try parse(#"{"with": ["lastMessage"]}"#).sortByLastMessage)
    #expect(try parse(#"{"with": [], "sort": "lastmessage"}"#).sortByLastMessage)
  }

  @Test("GET /chat/:guid keeps gating participants on `with`, which is the reference's asymmetry")
  func findStillGatesParticipants() {
    // Not parsed from a body: `.chatFind` builds its query from the query string, and the
    // reference's `chatRouter.find` reads `withQuery.includes("participants")` with no
    // fallback. Pinned here so the two routes are not "unified" into one behaviour.
    #expect(!ChatInterface.Query(withParticipants: false).withParticipants)
    #expect(ChatInterface.Query(withParticipants: true).withParticipants)
  }
}
