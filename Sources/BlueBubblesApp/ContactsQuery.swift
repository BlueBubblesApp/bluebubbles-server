//  ContactsQuery
//  What the Contacts page is asking the index for.
//
//  A reference type, and that is the whole reason it exists: `ScreenModel`'s read is a closure
//  built once in the view's `init`, so a value captured there would be frozen at whatever the
//  query was when the page first appeared. Every later page, search and sort has to reach the
//  same object.
//
//  Off the view for the usual reason: the clamping rule below is a decision, and touching a
//  SwiftUI `View` type from a test process traps.

import BBContacts
import Foundation
import Observation

@Observable
@MainActor
final class ContactsQuery {

  var search = ""
  var order: ContactIndex.ContactOrder = .name
  var ascending = true
  /// The first row of the page being shown, in the current ordering.
  private(set) var offset = 0

  /// Everything a change to which means the page has to be read again.
  ///
  /// One key rather than four `onChange` handlers: the read is the same read whichever of
  /// them moved, and `task(id:)` cancels the one in flight, which is what stops a burst of
  /// typing from leaving four reads racing to answer the same field.
  var reloadKey: String { "\(search)\u{1F}\(order.rawValue)\u{1F}\(ascending)\u{1F}\(offset)" }

  func page(to offset: Int) { self.offset = max(0, offset) }

  /// Back to the first page, for a change that redefines what the pages ARE.
  ///
  /// A new search or a new sort makes "page 4" mean something different, and staying on it
  /// shows an arbitrary window of a set the person has not seen the start of. Typing a
  /// surname and landing in the middle of the matches reads as search being broken.
  func resetPaging() { offset = 0 }

  /// Pulls the offset back into a set that has shrunk, and says whether it moved.
  ///
  /// The case this exists for is contacts being REMOVED while the page is open: a Google
  /// account unlinked, or a re-index after somebody deleted a group. Page 9 of 400 becomes an
  /// offset past the end, which answers with no rows — an empty table that looks like a
  /// failed read rather than a page that is no longer there.
  ///
  /// Returns false when nothing moved, so a caller can re-read only when it has to rather
  /// than on every page.
  @discardableResult
  func clamp(toTotal total: Int, pageSize: Int) -> Bool {
    guard pageSize > 0 else { return false }
    // An empty result belongs on the first page: there is no last page to fall back to, and
    // "showing 401-400 of 0" is the shape that produces.
    let last = total == 0 ? 0 : ((total - 1) / pageSize) * pageSize
    guard offset > last else { return false }
    offset = last
    return true
  }

  /// "Showing 1-100 of 4,214", or the same over the matches when a search is narrowing them.
  ///
  /// Counts from ONE, because the person is not reading an offset.
  func summary(showing count: Int, total: Int) -> String {
    guard total > 0, count > 0 else { return 0.counted("contact") }
    let first = offset + 1
    let last = min(offset + count, total)
    return "Showing \(first.formatted(.number))-\(last.formatted(.number)) of "
      + "\(total.formatted(.number))"
  }

  var hasPreviousPage: Bool { offset > 0 }

  func hasNextPage(total: Int, pageSize: Int) -> Bool { offset + pageSize < total }

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
