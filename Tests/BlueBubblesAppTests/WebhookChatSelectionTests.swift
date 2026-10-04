//  WebhookChatSelectionTests
//  A webhook's chat filter in the editor: when it is asked for, and what it saves.
//
//  The failures here are silent in the settings window. A stored GUID compared by spelling
//  shows as unticked after a macOS 26 upgrade and is saved over; a rule that hides the
//  section for a subscription that includes chat events leaves a filter nobody can see; and
//  a round trip that loses "Only selected" with nothing ticked snaps the control back the
//  moment it is chosen.

import BBEvents
import Testing

@testable import BlueBubblesApp

@Suite("Webhook chat selection")
struct WebhookChatSelectionTests {

  private static let direct = "iMessage;-;+12025550143"
  private static let migrated = "any;-;+12025550143"
  private static let group = "iMessage;+;chat100000000000000001"

  // MARK: - When the editor asks

  @Test("All events includes chat events")
  func wildcardAsks() {
    #expect(EventSubscription().includesChatEvents)
  }

  @Test("A subscription with any chat event asks, and one with none does not")
  func chosenEvents() {
    for event in EventName.chatScoped {
      let subscription = EventSubscription(isAllEvents: false, selected: [event.rawValue])
      #expect(subscription.includesChatEvents, "\(event)")
    }
    let serverOnly = EventSubscription(
      isAllEvents: false, selected: ["server-update", "new-findmy-location", "hello-world"])
    #expect(!serverOnly.includesChatEvents)
  }

  /// The picker offers a checkbox for each of these, so a chat event missing from the set
  /// would hide the section for exactly the subscription it should narrow.
  @Test("Every offered message and group event is one a chat filter applies to")
  func catalogMessageAndGroupEvents() {
    let groups = WebhookEventCatalog.groups.filter { ["Messages", "Groups"].contains($0.title) }
    #expect(groups.count == 2)
    for event in groups.flatMap(\.events) {
      #expect(EventName.chatScoped.contains(EventName(event.value)), "\(event.value)")
    }
  }

  // MARK: - Round trip

  @Test("A stored filter reads back as the same scope")
  func roundTrip() {
    for scope in [ChatScope.allChats, .only([Self.direct, Self.group]), .only([])] {
      #expect(WebhookChatSelection(scope: scope).scope == scope)
    }
  }

  @Test("Only selected with nothing ticked is not saveable")
  func emptyIsInvalid() {
    #expect(WebhookChatSelection().isValid)
    #expect(!WebhookChatSelection(isAllChats: false).isValid)
    #expect(WebhookChatSelection(isAllChats: false, selected: [Self.group]).isValid)
  }

  @Test("Switching to All conversations and back keeps what was ticked")
  func switchingKeepsSelection() {
    var selection = WebhookChatSelection(isAllChats: false, selected: [Self.group])
    selection.isAllChats = true
    #expect(selection.scope == .allChats)
    selection.isAllChats = false
    #expect(selection.scope == .only([Self.group]))
  }

  // MARK: - Comparing on the chat

  @Test("A GUID saved before the prefix changed is still ticked")
  func comparedOnTheChat() {
    let selection = WebhookChatSelection(isAllChats: false, selected: [Self.direct])
    #expect(selection.contains(Self.migrated))
    #expect(selection.unmatched(in: [Self.migrated]).isEmpty)
  }

  @Test("Toggling the same chat in another spelling unticks it rather than adding it twice")
  func toggleIsByChat() {
    var selection = WebhookChatSelection(isAllChats: false, selected: [Self.direct])
    selection.toggle(Self.migrated)
    #expect(selection.selected.isEmpty)
    selection.toggle(Self.group)
    selection.toggle(Self.migrated)
    #expect(selection.selected == [Self.group, Self.migrated])
  }

  @Test("A chosen chat missing from the list is reported, not dropped")
  func unmatchedIsKept() {
    let selection = WebhookChatSelection(isAllChats: false, selected: [Self.direct, Self.group])
    #expect(selection.unmatched(in: [Self.direct]) == [Self.group])
    #expect(selection.scope == .only([Self.direct, Self.group]))
  }

  // MARK: - The list row

  @Test("The row says nothing for every conversation and counts a chosen set")
  func summary() {
    #expect(WebhookChatSelection.summary(for: .allChats) == nil)
    #expect(WebhookChatSelection.summary(for: .only([Self.group])) == "Only from 1 conversation")
    #expect(
      WebhookChatSelection.summary(for: .only([Self.direct, Self.group]))
        == "Only from 2 conversations")
    #expect(WebhookChatSelection.summary(for: .only([]))?.contains("could not be read") == true)
  }
}
