//  AuditLogQuery
//  What the Audit Log page is asking the table for.
//
//  A reference type for the reason `ContactsQuery` is one: `ScreenModel`'s read is a closure
//  built once in the view's `init`, so a value captured there would be frozen at whatever the
//  query was when the page first appeared. Every later page, filter and search has to reach
//  the same object.
//
//  The paging rules are the contact page's, restated here rather than shared through a
//  generic, because the two pages differ in what a page IS: contacts are ordered by a column
//  the person picks, and audit records are always newest first. A shared type would carry an
//  order it only sometimes used.
//
//  Off the view for the usual reason: the clamping and the summary are decisions, and touching
//  a SwiftUI `View` type from a test process traps.

import BBAudit
import Foundation
import Observation

@Observable
@MainActor
final class AuditLogQuery {

  /// Empty means every category.
  var category: AuditCategory?
  /// Empty means every outcome.
  var outcome: AuditOutcome?
  var search = ""
  /// The first row of the page being shown, newest first.
  private(set) var offset = 0

  /// Everything a change to which means the page has to be read again, as one key so the
  /// read in flight is cancelled rather than raced; see `ContactsQuery.reloadKey`.
  var reloadKey: String {
    [category?.rawValue ?? "", outcome?.rawValue ?? "", search, String(offset)]
      .joined(separator: "\u{1F}")
  }

  /// The repository's shape of this query.
  var repositoryQuery: AuditQuery {
    var query = AuditQuery()
    if let category { query.categories = [category] }
    if let outcome { query.outcomes = [outcome] }
    query.search = search
    return query
  }

  /// Whether anything narrows the table. What the export records as `filtered`.
  var isFiltered: Bool { repositoryQuery.isFiltered }

  func page(to offset: Int) { self.offset = max(0, offset) }

  /// Back to the first page, for a change that redefines what the pages ARE: a new filter
  /// or a new search.
  func resetPaging() { offset = 0 }

  /// Pulls the offset back into a table that has shrunk (the retention sweep ran, or a
  /// filter narrowed the rows), and says whether it moved.
  @discardableResult
  func clamp(toTotal total: Int, pageSize: Int) -> Bool {
    guard pageSize > 0 else { return false }
    let last = total == 0 ? 0 : ((total - 1) / pageSize) * pageSize
    guard offset > last else { return false }
    offset = last
    return true
  }

  /// "Showing 1-100 of 4,214 records", counting from ONE.
  func summary(showing count: Int, total: Int) -> String {
    guard total > 0, count > 0 else { return 0.counted("record") }
    let first = offset + 1
    let last = min(offset + count, total)
    return "Showing \(first.formatted(.number))-\(last.formatted(.number)) of "
      + "\(total.formatted(.number))"
  }

  var hasPreviousPage: Bool { offset > 0 }

  func hasNextPage(total: Int, pageSize: Int) -> Bool { offset + pageSize < total }
}
