//  SearchDraft
//  What a search field holds while it is typed, and what the table is actually searched for.
//
//  A database-paged page reads its table again whenever its query changes, and a search that
//  is part of the query re-read the table on every keystroke. On the audit log that is a
//  `LIKE` over four columns of the whole table, on the one serial queue every `app.db` read
//  and write shares (measured at a million rows: 105 ms for a search that matches, 505 ms for
//  one that matches nothing), so typing a client's address held that queue for seconds in
//  front of settings writes and logins. Contacts did the same against the contact index.
//
//  So the field writes `text`, and only `committed` is part of a query: it moves when typing
//  pauses (`PausedSearchField`), on Return, and at once on clearing, which is not typing.
//
//  Off the view so the rule can be asserted; touching a SwiftUI `View` type from a test
//  process traps.

import Foundation

struct SearchDraft: Equatable, Sendable {

  /// What the field holds.
  var text = ""
  /// What the table is searched for.
  private(set) var committed = ""

  /// How long the field has to sit still before the table is searched.
  static let settle: Duration = .milliseconds(300)

  /// Makes the text the search. Returns whether that changed anything.
  @discardableResult
  mutating func commit() -> Bool {
    guard committed != text else { return false }
    committed = text
    return true
  }

  /// Empties the field and the search at once.
  mutating func clear() {
    text = ""
    commit()
  }
}
