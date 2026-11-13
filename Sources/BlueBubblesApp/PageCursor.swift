//  PageCursor
//  Where in a database-paged list the page being shown starts, and the rules for moving it.
//
//  Contacts and the Audit Log both read a page at a time from the database, and each carried
//  its own copy of the same five rules (move, go back to the first page, pull back into a set
//  that shrank, say where we are, whether there is a page either side), word for word. A
//  value type rather than a shared base: the two queries differ in everything else (what a
//  page is ordered by, whether a search waits for typing to pause), and they hold this as one
//  stored property.
//
//  The total is passed in rather than stored. It arrives with each read, on the same value as
//  the rows (see the Contacts section of `Sources/BlueBubblesApp/CLAUDE.md`), and a copy held
//  here would be one more thing to keep in step with it.
//
//  Off the view so the clamp, which is load-bearing, can be asserted: `PageCursorTests`.

import BBCore
import Foundation

struct PageCursor: Equatable, Sendable {

  /// How many rows one page holds. Not a ceiling: everything past it is one page away.
  let limit: Int
  /// The first row of the page being shown, counting from zero.
  private(set) var offset = 0

  init(limit: Int) {
    self.limit = limit
  }

  /// Moves to the page starting at `offset`, never before the first row.
  mutating func move(to offset: Int) { self.offset = max(0, offset) }

  mutating func previous() { move(to: offset - limit) }

  mutating func next() { move(to: offset + limit) }

  /// Back to the first page, for a change that redefines what the pages ARE.
  ///
  /// A new search, filter or sort makes "page 4" mean something different, and staying on it
  /// shows an arbitrary window of a set the person has not seen the start of. Typing a
  /// surname and landing in the middle of the matches reads as search being broken.
  mutating func reset() { offset = 0 }

  /// Pulls the offset back into a set that has shrunk, and says whether it moved.
  ///
  /// The case this exists for is rows being REMOVED while the page is open: a Google account
  /// unlinked, a re-index that finds fewer contacts, the audit retention sweep. Page 9 of 400
  /// becomes an offset past the end, which answers with no rows — an empty table that looks
  /// like a failed read rather than a page that is no longer there.
  ///
  /// Returns false when nothing moved, so a caller can re-read only when it has to rather
  /// than on every page.
  @discardableResult
  mutating func clamp(toTotal total: Int) -> Bool {
    guard limit > 0 else { return false }
    // An empty result belongs on the first page: there is no last page to fall back to, and
    // "showing 401-400 of 0" is the shape that produces.
    let last = total == 0 ? 0 : ((total - 1) / limit) * limit
    guard offset > last else { return false }
    offset = last
    return true
  }

  var hasPrevious: Bool { offset > 0 }

  func hasNext(total: Int) -> Bool { offset + limit < total }

  /// Whether there is more than one page, which is when a pager has anything to do.
  func isPaged(total: Int) -> Bool { total > limit }

  /// "Showing 101-200 of 4,214", counting from ONE, because the person is not reading an
  /// offset. With nothing to show, the count of `noun`: "0 records".
  func summary(showing count: Int, total: Int, noun: String) -> String {
    guard total > 0, count > 0 else { return 0.counted(noun) }
    let first = offset + 1
    let last = min(offset + count, total)
    return "Showing \(first.formatted(.number))-\(last.formatted(.number)) of "
      + "\(total.formatted(.number))"
  }
}
