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
