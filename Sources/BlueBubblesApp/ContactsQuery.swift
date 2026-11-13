//  ContactsQuery
//  What the Contacts page is asking the index for.
//
//  A reference type, and that is the whole reason it exists: `ScreenModel`'s read is a closure
//  built once in the view's `init`, so a value captured there would be frozen at whatever the
//  query was when the page first appeared. Every later page, search and sort has to reach the
//  same object.
//
//  Off the view for the usual reason: the ordering rule below is a decision, and touching a
//  SwiftUI `View` type from a test process traps. The paging rules, the clamp among them, are
//  `PageCursor`'s.

import BBContacts
import Foundation
import Observation

@Observable
@MainActor
final class ContactsQuery {

  /// How many contacts one page holds.
  ///
  /// Not a ceiling: everything past it is one click away, and search looks at the whole
  /// index rather than at what is loaded. A hundred fills a tall window without the read
  /// growing with the address book.
  static let pageSize = 100

  /// What the index is searched for, committed once typing pauses; see `SearchDraft`. The
  /// index is searched by the database, so a read per keystroke is a query per keystroke.
  var search = SearchDraft()
  var order: ContactIndex.ContactOrder = .name
  var ascending = true
  /// The page being shown, in the current ordering.
  var cursor = PageCursor(limit: ContactsQuery.pageSize)

  /// Everything a change to which means the page has to be read again.
  ///
  /// One key rather than four `onChange` handlers: the read is the same read whichever of
  /// them moved, and `task(id:)` cancels the one in flight, which is what stops a burst of
  /// typing from leaving four reads racing to answer the same field.
  var reloadKey: String {
    "\(search.committed)\u{1F}\(order.rawValue)\u{1F}\(ascending)\u{1F}\(cursor.offset)"
  }

  /// Which column the table was sorted by, as an order the database understands.
  ///
  /// A key path rather than a string: the table's comparators ARE key paths, and matching on
  /// one is checked by the compiler where matching on a column title is not. An unrecognised
  /// comparator falls back to name, which is the order the page opens in.
  static func order(for comparator: KeyPathComparator<ContactRowItem>) -> ContactIndex.ContactOrder
  {
    switch comparator.keyPath {
    case \ContactRowItem.phones: .phone
    case \ContactRowItem.emails: .email
    case \ContactRowItem.accountLabel: .account
    default: .name
    }
  }
}
