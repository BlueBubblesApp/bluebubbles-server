//  ConversationPicking
//  The rules behind every conversation picker in the app, off the view so a test can state
//  them.
//
//  One picker serves every page that chooses a conversation: the scheduled-message composer
//  and the transcript export choose one, a webhook's chat filter chooses several. The page
//  says which with `ConversationSelectionMode`, and everything that differs between the two
//  is decided here rather than in the view: what a click does, what the arrow keys move, what
//  Return does, and how a selection is summarised.
//
//  The keyboard rule is the part that differs most. With one choice the arrow keys move the
//  SELECTION, because there is nothing else to point at. With several they move a CURSOR and
//  Return toggles the row under it: moving a multi-selection on an arrow press would drop the
//  conversations already chosen. In both modes the list never takes focus from the search
//  field, so typing, arrowing and choosing happen without reaching for the mouse.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md` § Policy lives off the view.

import BBInterfaces
import Foundation

/// Whether a picker chooses one conversation or several. Set by the page, never by the
/// person: it is a property of what the choice is FOR.
enum ConversationSelectionMode: Equatable, Sendable {
  /// One conversation: a message goes to one place, a transcript is one conversation.
  case single
  /// Any number, including none: a filter over conversations.
  case multiple
}

enum ConversationPicking {

  /// The rows a query admits. The match itself is the directory's, so every picker searches
  /// the same spellings; see `ConversationDirectory.filter`.
  static func filter(
    _ conversations: [ConversationDirectory.Conversation], query: String
  ) -> [ConversationDirectory.Conversation] {
    ConversationDirectory.filter(conversations, query: query)
  }

  /// What a click on a row does to the selection.
  ///
  /// One: the row becomes the selection, and clicking it again keeps it; a picker that
  /// emptied itself on a second click would read as one that refused. Several: the row
  /// toggles in or out.
  static func selecting(
    _ guid: String, in selection: Set<String>, mode: ConversationSelectionMode
  ) -> Set<String> {
    switch mode {
    case .single:
      return [guid]
    case .multiple:
      var updated = selection
      if updated.remove(guid) == nil { updated.insert(guid) }
      return updated
    }
  }

  /// Where an arrow key moves the cursor, or nil when the press should be ignored.
  ///
  /// The first press ENTERS the list from the end pressed towards, so it lands where the eye
  /// already is; a cursor the query has filtered out re-enters the same way; the ends clamp
  /// rather than wrap, because wrapping from the last result to the first looks like the list
  /// jumped somewhere else.
  static func cursor(
    movedBy offset: Int, in rows: [ConversationDirectory.Conversation], from current: String?
  ) -> String? {
    guard !rows.isEmpty else { return nil }
    guard let current, let index = rows.firstIndex(where: { $0.id == current }) else {
      return (offset > 0 ? rows.first : rows.last)?.id
    }
    return rows[min(max(index + offset, 0), rows.count - 1)].id
  }

  /// Where the cursor sits before any arrow is pressed: on the selection when there is one
  /// conversation chosen, so the arrows move on from it; nowhere otherwise.
  static func initialCursor(
    selection: Set<String>, mode: ConversationSelectionMode
  ) -> String? {
    mode == .single ? selection.first : nil
  }

  /// What an arrow press does to the selection: in single mode the cursor IS the selection,
  /// in multiple mode an arrow only moves the cursor and the selection is left alone.
  static func selection(
    afterMovingTo cursor: String, from selection: Set<String>, mode: ConversationSelectionMode
  ) -> Set<String> {
    mode == .single ? [cursor] : selection
  }

  /// The row Return acts on, or nil when Return should do nothing here.
  ///
  /// Several: the row under the cursor when it is still on screen, otherwise the top result.
  /// One: the top result, and ONLY while nothing is chosen. Once a conversation is chosen,
  /// Return belongs to the form the picker sits in (Schedule, Export), which is what someone
  /// finishing the form expects it to do.
  static func returnTarget(
    cursor: String?, in rows: [ConversationDirectory.Conversation],
    selection: Set<String>, mode: ConversationSelectionMode
  ) -> String? {
    switch mode {
    case .single:
      return selection.isEmpty ? rows.first?.id : nil
    case .multiple:
      if let cursor, rows.contains(where: { $0.id == cursor }) { return cursor }
      return rows.first?.id
    }
  }

  /// The chosen conversations in the order the list shows them, with any the list does not
  /// hold (an older conversation past the list's limit, or one a webhook was saved with and
  /// that no longer exists) after them by GUID, so nothing chosen is ever hidden.
  static func chosen(
    _ selection: Set<String>, in conversations: [ConversationDirectory.Conversation]
  ) -> (known: [ConversationDirectory.Conversation], unknown: [String]) {
    let known = conversations.filter { selection.contains($0.id) }
    let knownIDs = Set(known.map(\.id))
    let unknown = selection.subtracting(knownIDs).sorted()
    return (known, unknown)
  }
}
