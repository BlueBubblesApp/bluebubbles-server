//  ConversationPickingTests
//  What a click, an arrow and Return do in the shared conversation picker, in each mode.
//
//  The picker serves a page choosing one conversation (the composer, the export) and a page
//  choosing several (a webhook filter). The two differ in exactly the places tested here, and
//  each difference is one someone can get wrong without it looking wrong: an arrow press that
//  drops a multi-selection, a second click that empties a single one, a Return that steals
//  the form's default action.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBInterfaces
import Testing

@testable import BlueBubblesApp

@Suite("Conversation picking")
struct ConversationPickingTests {

  private var three: [ConversationDirectory.Conversation] {
    ["+12025550143", "+12025550144", "+12025550145"].map { address in
      ConversationDirectory.Conversation(
        guid: "iMessage;-;\(address)", isGroup: false,
        participants: [ConversationDirectory.Participant(address: address)])
    }
  }

  // MARK: Clicking

  @Test("In single mode a click replaces the selection and a second click keeps it")
  func singleClick() {
    let rows = three
    let first = ConversationPicking.selecting(rows[0].id, in: [], mode: .single)
    #expect(first == [rows[0].id])
    let second = ConversationPicking.selecting(rows[1].id, in: first, mode: .single)
    #expect(second == [rows[1].id])
    #expect(ConversationPicking.selecting(rows[1].id, in: second, mode: .single) == second)
  }

  @Test("In multiple mode a click toggles the row in and out")
  func multipleClick() {
    let rows = three
    var selection = ConversationPicking.selecting(rows[0].id, in: [], mode: .multiple)
    selection = ConversationPicking.selecting(rows[2].id, in: selection, mode: .multiple)
    #expect(selection == [rows[0].id, rows[2].id])
    selection = ConversationPicking.selecting(rows[0].id, in: selection, mode: .multiple)
    #expect(selection == [rows[2].id])
  }

  // MARK: Arrows

  @Test("A first press enters from the end pressed towards; the ends clamp")
  func cursorMoves() {
    let rows = three
    #expect(ConversationPicking.cursor(movedBy: 1, in: rows, from: nil) == rows[0].id)
    #expect(ConversationPicking.cursor(movedBy: -1, in: rows, from: nil) == rows[2].id)
    #expect(ConversationPicking.cursor(movedBy: 1, in: rows, from: rows[0].id) == rows[1].id)
    #expect(ConversationPicking.cursor(movedBy: 99, in: rows, from: rows[0].id) == rows[2].id)
    #expect(ConversationPicking.cursor(movedBy: -99, in: rows, from: rows[2].id) == rows[0].id)
    #expect(ConversationPicking.cursor(movedBy: 1, in: rows, from: "gone") == rows[0].id)
    #expect(ConversationPicking.cursor(movedBy: 1, in: [], from: nil) == nil)
  }

  @Test("An arrow moves a single selection and leaves a multiple one alone")
  func arrowsAndSelection() {
    let rows = three
    let moved = ConversationPicking.selection(
      afterMovingTo: rows[1].id, from: [rows[0].id], mode: .single)
    #expect(moved == [rows[1].id])
    let kept = ConversationPicking.selection(
      afterMovingTo: rows[1].id, from: [rows[0].id, rows[2].id], mode: .multiple)
    #expect(kept == [rows[0].id, rows[2].id])
  }

  @Test("The cursor starts on a single selection and nowhere in multiple mode")
  func initialCursor() {
    #expect(ConversationPicking.initialCursor(selection: ["a"], mode: .single) == "a")
    #expect(ConversationPicking.initialCursor(selection: ["a"], mode: .multiple) == nil)
    #expect(ConversationPicking.initialCursor(selection: [], mode: .single) == nil)
  }

  // MARK: Return

  @Test("Return picks the top hit once in single mode, then belongs to the form")
  func singleReturn() {
    let rows = three
    #expect(
      ConversationPicking.returnTarget(cursor: nil, in: rows, selection: [], mode: .single)
        == rows[0].id)
    #expect(
      ConversationPicking.returnTarget(
        cursor: nil, in: rows, selection: [rows[1].id], mode: .single) == nil)
  }

  @Test("Return toggles the row under the cursor in multiple mode")
  func multipleReturn() {
    let rows = three
    #expect(
      ConversationPicking.returnTarget(
        cursor: rows[2].id, in: rows, selection: [rows[0].id], mode: .multiple) == rows[2].id)
    // A cursor the query has filtered out falls back to the top result.
    #expect(
      ConversationPicking.returnTarget(
        cursor: "gone", in: rows, selection: [], mode: .multiple) == rows[0].id)
    #expect(
      ConversationPicking.returnTarget(cursor: nil, in: [], selection: [], mode: .multiple)
        == nil)
  }

  // MARK: The summary

  @Test("A selection the list does not hold is still shown, by GUID")
  func chosenIncludesUnknown() {
    let rows = three
    let chosen = ConversationPicking.chosen([rows[1].id, "iMessage;+;old-chat"], in: rows)
    #expect(chosen.known.map(\.id) == [rows[1].id])
    #expect(chosen.unknown == ["iMessage;+;old-chat"])
  }
}
