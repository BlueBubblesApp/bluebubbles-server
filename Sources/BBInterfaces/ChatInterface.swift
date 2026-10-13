//  ChatInterface
//  Chat operations, independent of how they were asked for.
//
//  See MessageInterface for why this layer exists.

import BBAppleScript
import BBCore
import BBEvents
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
  /// Which macOS this is, for the capability gates in `+Administration`.
  ///
  /// A stored property rather than a call to `ProcessInfo` at the point of use, for the same
  /// reason `MessageInterface` has one: a gate that reads the real OS is a gate no test on
  /// this machine can exercise for any release but this one, and a version gate that has
  /// only ever run on the release it permits is not a gate anybody has checked.
  let osMajorVersion: Int
  /// The message read path, for a chat's messages and for matching a create's message back.
  ///
  /// Held, not built per call: a `MessageInterface` carries the attachment-metadata cache,
  /// and one built per call starts that cache empty every time, so every chat-scoped read
  /// re-probed every attachment off disk. The composition root passes the bundle's own, so
  /// the chat routes and the message routes share one cache. Its helper goes unused here:
  /// both calls are chat.db reads.
  let messageReader: MessageInterface
  /// Where `markUnread` announces itself. Nil in a test that does not look; the composition
  /// root always passes the server's bus, and `EventDeliveryWiringTests` drives that.
  let events: EventBus?

  public init(
    repository: MessageRepository,
    serializer: MessageSerializer,
    messages: MessageInterface? = nil,
    privateAPI: Helper? = nil,
    appleScript: AppleScriptMessageSender = AppleScriptMessageSender(),
    shortcuts: GroupChatShortcutManager? = nil,
    addressFormatter: AddressFormatter = .shared,
    logger: Logger = Logger(label: "bluebubbles.interface.chat"),
    osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
    events: EventBus? = nil
  ) {
    self.repository = repository
    self.serializer = serializer
    self.privateAPI = privateAPI
    self.appleScript = appleScript
    self.shortcuts = shortcuts
    self.addressFormatter = addressFormatter
    self.logger = logger
    self.osMajorVersion = osMajorVersion
    self.events = events
    self.messageReader =
      messages ?? MessageInterface(repository: repository, serializer: serializer)
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
      // Clamped, like every paged route here; see `Page`. The reference's rule is
      // `limit: numeric|min:1|max:1000` (`validators/chatValidator.ts:26`), and unclamped,
      // `{"limit": -1}` returned every chat in the database and then hydrated participants
      // for each one.
      let page = Page(limit: limit, offset: offset)
      self.limit = page.limit
      self.offset = page.offset
      self.includeArchived = includeArchived
      self.withParticipants = withParticipants
      self.withLastMessage = withLastMessage
      self.sortByLastMessage = sortByLastMessage
    }

    /// The window this query serves, for the listing's metadata.
    public var page: Page { Page(limit: limit, offset: offset) }

    public static func parse(_ body: JSONValue) -> Query {
      let relations = RequestedRelations(body["with"]).names

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
