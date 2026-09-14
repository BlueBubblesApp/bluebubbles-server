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

  let repository: MessageRepository
  let serializer: MessageSerializer
  /// The roles this interface calls, and no more.
  ///
  /// `MessageMutation` is in the list for `deleteMessage` alone: clearing one message out
  /// of a conversation is a chat operation to a caller and a message operation to Messages.
  public typealias Helper = any PrivateAPIConnection & ChatAdministration & ChatMuting
    & ChatFiltering & ChatPresence & MessageMutation

  let privateAPI: Helper?
  /// The one-to-one creation path. Not optional: it needs no install and no permission
  /// beyond the Automation grant sending already requires, so there is no configuration in
  /// which it is absent.
  let appleScript: AppleScriptMessageSender
  /// The group creation path, when the user has set it up. Nil when the feature is not
  /// available at all: an app build without it, or a test that does not exercise it.
  let shortcuts: GroupChatShortcutManager?
  /// Shared with the sender, so "the same address" means the same thing on both sides of a
  /// create-then-look-up round trip. Two formatters with different default regions would
  /// resolve `+1…` and a local number differently and the lookup would silently miss.
  let addressFormatter: AddressFormatter
  let logger: Logger

  public init(
    repository: MessageRepository,
    serializer: MessageSerializer,
    privateAPI: Helper? = nil,
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

  // MARK: - The query, and what a picker needs

  public struct Query: Sendable {
    /// Filter to one chat, matched across every service-prefix spelling.
    ///
    /// The reference reads `body.guid` and applies it; this server parsed the body and had
    /// nowhere to put it, so a client filtering by GUID was handed up to a thousand chats
    /// with a 200, participants hydrated for each, and a `total` counting the whole
    /// database. The client cannot tell: the shape is right and the status is right.
    public var guid: String?
    public var limit: Int
    public var offset: Int
    public var includeArchived: Bool
    public var withParticipants: Bool
    public var withLastMessage: Bool
    public var sortByLastMessage: Bool

    public init(
      guid: String? = nil,
      limit: Int = 1000,
      offset: Int = 0,
      includeArchived: Bool = true,
      withParticipants: Bool = true,
      withLastMessage: Bool = false,
      sortByLastMessage: Bool = false
    ) {
      self.guid = guid.flatMap { $0.isEmpty ? nil : $0 }
      // Clamped, like `MessageQuery`. The reference's rule is `limit: numeric|min:1|max:1000`
      // (`validators/chatValidator.ts:26`) and this was the one paged route that applied
      // neither half: the value went straight into `LIMIT ?`, and **SQLite reads a negative
      // LIMIT as no limit at all**, so `{"limit": -1}` returned every chat in the database
      // and then hydrated participants for each one.
      //
      // Clamped rather than rejected on purpose. A 400 would match the reference, but
      // clamping is safe in both directions and every other paged route here already
      // clamps; a client asking for more than the cap has always been given the cap.
      self.limit = min(max(1, limit), 1000)
      self.offset = max(0, offset)
      self.includeArchived = includeArchived
      self.withParticipants = withParticipants
      self.withLastMessage = withLastMessage
      self.sortByLastMessage = sortByLastMessage
    }

    public static func parse(_ body: JSONValue) -> Query {
      let relations = (body["with"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        .map { $0.lowercased() }

      // BOTH spellings, because the reference accepts both:
      // `arrayHasOne(withQuery, ["lastmessage", "last-message"])` (`chatRouter.ts:124`).
      // Matched exactly rather than by `contains`, which read `last-message` as neither.
      let wantsLastMessage = relations.contains { $0 == "lastmessage" || $0 == "last-message" }

      // `sort` is FORCED when the last message was asked for and no sort was given, which
      // is what the reference does in two places (`chatRouter.ts:130-132` and
      // `chatInterface.ts:32`). Without it a conversation list came back in ROWID order
      // there and last-message order here: the same request, a different order.
      let sort = body["sort"]?.stringValue?.lowercased()

      return Query(
        guid: body["guid"]?.stringValue,
        limit: body["limit"]?.intValue ?? 1000,
        offset: body["offset"]?.intValue ?? 0,
        // `false` only when explicitly asked; the default includes archived chats.
        includeArchived: body["includeArchived"]?.boolValue ?? true,
        // UNCONDITIONAL, and `with` is not consulted. The reference reads `with` for the
        // last message alone and calls `ChatInterface.get`, which calls `getChats` without
        // `withParticipants` and so takes its default of `true`
        // (`interfaces/chatInterface.ts:37`, `databases/imessage/index.ts:68`); it then
        // serializes under `DEFAULT_CHAT_CONFIG`, whose `includeParticipants` is true too.
        //
        // This was `relations.isEmpty ? true : wants("participant")`, which defaulted to
        // true only while `with` was EMPTY and inverted the moment a client asked for
        // anything. The full sync asks for `["lastMessage"]`, so it got `participants: []`
        // on every chat — and `full_sync_manager.dart` reads an empty participant list as
        // "this chat is not real" and SOFT-DELETES it. A fresh sync reported no chats to
        // sync and removed every conversation it had just been handed.
        //
        // `GET /chat/:guid` genuinely does gate participants on `with`; that asymmetry is
        // the reference's and is pinned by `ChatQueryParticipantsTests`.
        withParticipants: true,
        withLastMessage: wantsLastMessage,
        sortByLastMessage: sort == "lastmessage" || (wantsLastMessage && sort == nil)
      )
    }
  }

  /// Just enough of a chat to offer it in a picker.
  ///
  /// Three fields against a whole `ChatRow`, and no last-message load. `query` already
  /// returns `ChatProjection` values and serializes nothing unless asked, so this exists for
  /// the narrowness alone.
  ///
  /// A caller that wants more should use `query` directly rather than growing this type;
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
}
