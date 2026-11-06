//  AuditLogQuery
//  What the Audit Log page is asking the table for.
//
//  A reference type for the reason `ContactsQuery` is one: `ScreenModel`'s read is a closure
//  built once in the view's `init`, so a value captured there would be frozen at whatever the
//  query was when the page first appeared. Every later page, filter and search has to reach
//  the same object.
//
//  The paging rules are the contact page's, shared as `PageCursor`, a value this holds: the
//  two pages differ in what a page is ORDERED by (a column the person picks, against always
//  newest first), so the order stays here and only the cursor is shared.
//
//  Off the view for the usual reason: the search rules are decisions, and touching a SwiftUI
//  `View` type from a test process traps.

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
  /// What the table is searched for, and what the field holds while it is typed; only the
  /// committed half is part of the query. See `SearchDraft`.
  var search = SearchDraft()

  /// How many records one page holds. Not a ceiling: everything older is one click away.
  static let pageSize = 100

  /// The page being shown, newest first.
  var cursor = PageCursor(limit: AuditLogQuery.pageSize)

  /// Everything a change to which means the page has to be read again, as one key so the
  /// read in flight is cancelled rather than raced; see `ContactsQuery.reloadKey`.
  var reloadKey: String {
    [category?.rawValue ?? "", outcome?.rawValue ?? "", search.committed, String(cursor.offset)]
      .joined(separator: "\u{1F}")
  }

  /// The repository's shape of this query.
  var repositoryQuery: AuditQuery {
    var query = AuditQuery()
    if let category { query.categories = [category] }
    if let outcome { query.outcomes = [outcome] }
    query.search = search.committed
    return query
  }

  /// Whether anything narrows the table. What the export records as `filtered`.
  var isFiltered: Bool { repositoryQuery.isFiltered }
}
