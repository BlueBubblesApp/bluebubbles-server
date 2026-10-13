//  AuditLogQueryTests
//  Paging over a table that is always newest first and can shrink underneath the page.

import BBAudit
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Audit log query")
@MainActor
struct AuditLogQueryTests {

  @Test("A filter narrows the repository query and marks it filtered")
  func repositoryQuery() {
    let query = AuditLogQuery()
    #expect(!query.isFiltered)
    #expect(query.repositoryQuery == AuditQuery())

    query.category = .authentication
    query.outcome = .denied
    query.search.text = "113"
    query.search.commit()
    #expect(query.isFiltered)
    #expect(query.repositoryQuery.categories == [.authentication])
    #expect(query.repositoryQuery.outcomes == [.denied])
    #expect(query.repositoryQuery.search == "113")
  }

  @Test("The reload key moves with every part of the query")
  func reloadKey() {
    let query = AuditLogQuery()
    var keys: Set<String> = [query.reloadKey]
    query.category = .settings
    keys.insert(query.reloadKey)
    query.outcome = .failure
    keys.insert(query.reloadKey)
    query.search.text = "x"
    query.search.commit()
    keys.insert(query.reloadKey)
    query.cursor.move(to: 100)
    keys.insert(query.reloadKey)
    #expect(keys.count == 5)
  }

  /// Typing must not re-read the table: each read of a search is a scan of the whole table on
  /// the queue every `app.db` reader shares. Only a commit moves the key the page reloads on.
  @Test("Typing in the search field does not move the reload key until it is committed")
  func searchIsCommittedNotTyped() {
    let query = AuditLogQuery()
    let before = query.reloadKey
    query.search.text = "203.0"
    #expect(query.reloadKey == before)
    #expect(query.repositoryQuery.search == "")

    let committed = query.search.commit()
    #expect(committed)
    #expect(query.reloadKey != before)
    #expect(query.repositoryQuery.search == "203.0")
    // Committing the same text again is not a change, so it reads nothing.
    let recommitted = query.search.commit()
    #expect(!recommitted)

    query.search.clear()
    #expect(query.search.text == "")
    #expect(query.repositoryQuery.search == "")
  }

  // The paging rules themselves are `PageCursor`'s, asserted in `PageCursorTests`.
  @Test("A page holds a hundred records")
  func pageSize() {
    #expect(AuditLogQuery().cursor.limit == 100)
  }
}
