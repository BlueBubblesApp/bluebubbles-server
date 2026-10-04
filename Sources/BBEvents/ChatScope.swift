//  ChatScope
//  Which conversation an event is about, and narrowing a delivery target to some of them.
//
//  An event does not carry its chat as a field: the payload is the wire shape, and that shape
//  differs per event. So the one place that knows where each chat-bearing event keeps its GUID
//  is `ServerEvent.chatGUIDs`, keyed on the event name, and `EventName.chatScoped` is that same
//  knowledge as a set, for a picker deciding whether a chat filter is worth asking about. A
//  test builds each event the way its emitter does and asserts the two agree; an event added
//  to the set with no case in the switch would otherwise be filtered on a GUID it never finds.
//
//  GUIDs are compared with `ChatGUID.sameChat`, never `==`. A filter saved before a macOS 26
//  upgrade holds `iMessage;-;…`, and the events that follow it carry `any;-;…` for the same
//  conversation; an exact match would silently stop delivering it.
//
//  See `docs/EVENTS.md`.

import BBCore
import BBSerialization

extension EventName {

  /// Events whose payload is a serialized message, with the conversation in its `chats`.
  ///
  /// Read from `fullPayload`, whose `.full` configuration always includes the chats. The
  /// notification projection does not: `.notificationUpdate` leaves them out to stay under
  /// Firebase's 4 KB cap, so an `updated-message` webhook body has no chat in it.
  static let messageShaped: Set<EventName> = [
    .newMessage, .updatedMessage, .messageSendError,
    .groupNameChange, .groupIconChanged, .groupIconRemoved,
    .participantAdded, .participantRemoved, .participantLeft,
  ]

  /// Every event that is about one conversation, and so can be narrowed to chosen chats.
  ///
  /// Everything else (a server update, a FindMy location, a FaceTime call, a backup) has no
  /// chat to compare, and a chat filter leaves it alone.
  public static let chatScoped: Set<EventName> = messageShaped.union([
    // `{ guid, display }`, built in `PrivateAPIGatedService.serverEvent(for:)`.
    .typingIndicator,
    // `{ chatGuid, read }`: the reference's `emitMessage(CHAT_READ_STATUS_CHANGED, …)`
    // in `server/index.ts` and `chatInterface.ts`.
    .chatReadStatusChanged,
    // The scheduled message record, whose `payload.chatGuid` is the conversation it sends
    // to. Built in `ScheduledMessageService` from `ScheduledMessage.json`.
    .scheduledMessageError, .scheduledMessageSent,
  ])
}

extension ServerEvent {

  /// The conversations this event is about, or nil when it is not about one.
  ///
  /// Empty is distinct from nil: it is a chat-bearing event whose chat could not be read
  /// from the payload, which a chat filter refuses rather than waves through.
  public var chatGUIDs: [String]? {
    guard EventName.chatScoped.contains(name) else { return nil }
    let payload = fullPayload
    let found: [String?]
    if EventName.messageShaped.contains(name) {
      found = payload["chats"]?.arrayValue?.map { $0["guid"]?.stringValue } ?? []
    } else {
      switch name {
      case .typingIndicator: found = [payload["guid"]?.stringValue]
      case .chatReadStatusChanged: found = [payload["chatGuid"]?.stringValue]
      default: found = [payload["payload"]?["chatGuid"]?.stringValue]
      }
    }
    return found.compactMap { $0 }.filter { !$0.isEmpty }
  }
}

/// Which conversations a delivery target receives chat events for.
public enum ChatScope: Sendable, Equatable {
  /// Every conversation. What a target with no filter gets.
  case allChats
  /// Only these conversations, by chat GUID.
  ///
  /// Empty means NO conversation: every chat event is withheld, and the events that are not
  /// about a chat still arrive. The settings window refuses to save it; the type allows it
  /// because a stored list that could not be read lands here, and nothing is the safe reading
  /// of a filter that cannot be read.
  case only([String])

  /// Whether this scope lets an event through.
  ///
  /// An event that is not about a chat always passes: the filter narrows chat events, it is
  /// not a second event filter. A chat event passes when any conversation it names is one of
  /// the chosen ones; one whose chat cannot be read is withheld, because a filter that let
  /// through what it cannot identify would deliver exactly the conversations it was set up to
  /// keep out.
  public func admits(_ event: ServerEvent) -> Bool {
    admits(chatGUIDs: event.chatGUIDs)
  }

  /// `admits(_:)` against GUIDs already read from the event, so a sink checking one event
  /// against many targets reads the payload once.
  public func admits(chatGUIDs: [String]?) -> Bool {
    guard case .only(let chosen) = self, let chatGUIDs else { return true }
    return chatGUIDs.contains { guid in
      chosen.contains { ChatGUID.sameChat($0, guid) }
    }
  }
}
