//  WebhookChatSelection
//  A webhook's chat filter while it is being edited.
//
//  Off the view for the reason `EventSubscription` is: touching a SwiftUI `View` type from a
//  test process traps, and the parts that can go wrong silently are here. The round trip
//  through `ChatScope`, the comparison of a stored GUID against the conversation list, and the
//  rule for when the editor asks at all.
//
//  The comparison is the one worth reading. A filter saved before a macOS 26 upgrade holds
//  `iMessage;-;…` and the conversation list afterwards reads `any;-;…` for the same chat, so
//  "is this row ticked" is `ChatGUID.sameChat`, never `contains`. With `contains`, opening that
//  webhook would show nothing ticked and a stored GUID nobody could see.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBCore
import BBEvents

struct WebhookChatSelection: Equatable, Sendable {

  /// Every conversation. What a webhook with no filter has.
  var isAllChats: Bool
  /// Chat GUIDs in the order they were chosen, so the list of chosen conversations does not
  /// reshuffle as one is added.
  private(set) var selected: [String]

  init(isAllChats: Bool = true, selected: [String] = []) {
    self.isAllChats = isAllChats
    self.selected = selected
  }

  /// Reads a stored filter.
  init(scope: ChatScope) {
    switch scope {
    case .allChats: self.init(isAllChats: true)
    case .only(let guids): self.init(isAllChats: false, selected: guids)
    }
  }

  /// What is saved. The chosen GUIDs are kept even while "All conversations" is showing, so
  /// switching back and forth does not throw a selection away; `scope` is what decides.
  var scope: ChatScope { isAllChats ? .allChats : .only(selected) }

  /// Whether this is safe to save. "Only selected" with nothing selected withholds every chat
  /// event, which is the one state worth refusing, the same rule `EventSubscription.isValid`
  /// applies to events.
  var isValid: Bool { isAllChats || !selected.isEmpty }

  /// Whether a conversation is chosen, compared on the chat rather than on the spelling.
  func contains(_ guid: String) -> Bool {
    selected.contains { ChatGUID.sameChat($0, guid) }
  }

  mutating func toggle(_ guid: String) {
    if contains(guid) { remove(guid) } else { selected.append(guid) }
  }

  mutating func remove(_ guid: String) {
    selected.removeAll { ChatGUID.sameChat($0, guid) }
  }

  mutating func removeAll() { selected.removeAll() }

  /// Chosen GUIDs that match no conversation in `available`: a chat that has since been
  /// deleted, or one older than the conversations the picker reads.
  ///
  /// Shown rather than dropped, for the reason `EventSubscriptionPicker` shows an event name
  /// it has no checkbox for: otherwise it is a filter nothing in the app can see or undo.
  func unmatched(in available: [String]) -> [String] {
    selected.filter { guid in !available.contains { ChatGUID.sameChat($0, guid) } }
  }

  /// What a webhook's chat filter reads as in the list, or nil when there is none.
  static func summary(for scope: ChatScope) -> String? {
    guard case .only(let guids) = scope else { return nil }
    // Empty is a stored list that could not be read (the settings window refuses to save
    // one), and every chat event is withheld.
    guard !guids.isEmpty else {
      return "No conversations: its conversation list could not be read. Edit it to choose again."
    }
    return "Only from \(guids.count.counted("conversation"))"
  }
}

extension EventSubscription {

  /// Whether this subscription includes an event about a conversation, and so whether a chat
  /// filter would narrow anything.
  ///
  /// The wildcard does: it includes every chat event. A name this build does not know is
  /// treated as not being about a chat, because nothing here knows where its chat would be.
  var includesChatEvents: Bool {
    isAllEvents || selected.contains { EventName.chatScoped.contains(EventName($0)) }
  }
}
