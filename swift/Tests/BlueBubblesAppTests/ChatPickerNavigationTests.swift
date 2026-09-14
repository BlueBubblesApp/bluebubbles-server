//  ChatPickerNavigationTests
//  Searching and arrow-keying the conversation picker.
//
//  `ScheduleComposer`'s labelling was already testable and tested; these two were not. The
//  filter was a computed property over `@State` and the arrow rule wrote to `@State` in
//  place, so neither could be reached — and both are decisions someone can get wrong without
//  it looking wrong: a whitespace query matching everything, or an arrow key wrapping the
//  list round when it should stop.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBInterfaces
import Testing

@testable import BlueBubblesApp

@Suite("Chat picker navigation")
struct ChatPickerNavigationTests {

  private func choices(_ addresses: [String]) -> [ScheduleComposer.ChatChoice] {
    addresses.compactMap { address in
      ScheduleComposer.choice(
        for: ChatInterface.ChatSummary(
          guid: "iMessage;-;\(address)", displayName: nil, participants: [address]))
    }
  }

  private var three: [ScheduleComposer.ChatChoice] {
    choices(["+12025550143", "+12025550144", "+12025550145"])
  }

  // MARK: - Searching

  @Test("An empty query filters nothing")
  func emptyQuery() {
    #expect(ChatPickerNavigation.filter(three, query: "").count == 3)
  }

  /// A query of only spaces is NO query. Untrimmed it matched every label containing a
  /// space, which is most of them, so the list appeared not to filter at all.
  @Test("A whitespace-only query is no query, not a match-everything one")
  func whitespaceQuery() {
    #expect(ChatPickerNavigation.filter(three, query: "   ").count == 3)
    #expect(ChatPickerNavigation.filter(three, query: "\t ").count == 3)
  }

  @Test("A query is trimmed before it is matched")
  func queryIsTrimmed() {
    #expect(ChatPickerNavigation.filter(three, query: "  0143  ").count == 1)
  }

  @Test("A query matching nothing gives nothing")
  func noMatches() {
    #expect(ChatPickerNavigation.filter(three, query: "zzzz").isEmpty)
  }

  // MARK: - Arrow keys

  @Test("With no results, an arrow key is ignored")
  func emptyListIgnores() {
    #expect(ChatPickerNavigation.selection(movedBy: 1, in: [], from: "") == nil)
    #expect(ChatPickerNavigation.selection(movedBy: -1, in: [], from: "") == nil)
  }

  /// The first press ENTERS the list from the end it is pressed towards, so the selection
  /// lands where the eye already is rather than always at the top.
  @Test("A first press enters from the end it is pressed towards")
  func firstPressEnters() {
    let rows = three
    #expect(ChatPickerNavigation.selection(movedBy: 1, in: rows, from: "") == rows.first?.guid)
    #expect(ChatPickerNavigation.selection(movedBy: -1, in: rows, from: "") == rows.last?.guid)
  }

  /// A selection the current query has filtered out is not in the list, so the next press is
  /// an entry rather than a move from a row that is not on screen.
  @Test("A selection no longer in the results is re-entered, not moved from")
  func staleSelectionReEnters() {
    let rows = three
    let gone = "iMessage;-;+12025550199"
    #expect(ChatPickerNavigation.selection(movedBy: 1, in: rows, from: gone) == rows.first?.guid)
  }

  @Test("Down moves down and up moves up")
  func movesOneStep() {
    let rows = three
    #expect(
      ChatPickerNavigation.selection(movedBy: 1, in: rows, from: rows[0].guid) == rows[1].guid)
    #expect(
      ChatPickerNavigation.selection(movedBy: -1, in: rows, from: rows[2].guid) == rows[1].guid)
  }

  /// Clamped, not wrapped. Wrapping from the last result back to the first looks like the
  /// list jumped somewhere else.
  @Test("The ends clamp rather than wrapping round")
  func endsClamp() {
    let rows = three
    #expect(
      ChatPickerNavigation.selection(movedBy: 1, in: rows, from: rows[2].guid) == rows[2].guid)
    #expect(
      ChatPickerNavigation.selection(movedBy: -1, in: rows, from: rows[0].guid) == rows[0].guid)
  }

  @Test("A single result is its own answer in both directions")
  func singleResult() {
    let one = choices(["+12025550143"])
    #expect(ChatPickerNavigation.selection(movedBy: 1, in: one, from: one[0].guid) == one[0].guid)
    #expect(ChatPickerNavigation.selection(movedBy: -1, in: one, from: "") == one[0].guid)
  }

  /// A jump larger than the list cannot land outside it: the clamp is on the result, not on
  /// the step.
  @Test("An offset past either end still lands inside the list")
  func largeOffsetClamps() {
    let rows = three
    #expect(
      ChatPickerNavigation.selection(movedBy: 99, in: rows, from: rows[0].guid) == rows[2].guid)
    #expect(
      ChatPickerNavigation.selection(movedBy: -99, in: rows, from: rows[2].guid) == rows[0].guid)
  }
}
