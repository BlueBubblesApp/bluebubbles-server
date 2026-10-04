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
    query.search = "113"
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
    query.search = "x"
    keys.insert(query.reloadKey)
    query.page(to: 100)
    keys.insert(query.reloadKey)
    #expect(keys.count == 5)
  }

  @Test("Paging never goes below the first row and clamps into a shrunken table")
  func paging() {
    let query = AuditLogQuery()
    query.page(to: -50)
    #expect(query.offset == 0)
    #expect(!query.hasPreviousPage)
    #expect(query.hasNextPage(total: 150, pageSize: 100))
    #expect(!query.hasNextPage(total: 100, pageSize: 100))

    query.page(to: 300)
    #expect(query.clamp(toTotal: 150, pageSize: 100))
    #expect(query.offset == 100)
    #expect(!query.clamp(toTotal: 150, pageSize: 100), "already in range")
    #expect(query.clamp(toTotal: 0, pageSize: 100))
    #expect(query.offset == 0)
  }

  @Test("The summary counts from one")
  func summary() {
    let query = AuditLogQuery()
    query.page(to: 100)
    #expect(query.summary(showing: 100, total: 250) == "Showing 101-200 of 250")
    #expect(query.summary(showing: 50, total: 150) == "Showing 101-150 of 150")
    #expect(query.summary(showing: 0, total: 0) == "0 records")
  }

  @Test("Resetting paging goes back to the first page")
  func resetPaging() {
    let query = AuditLogQuery()
    query.page(to: 200)
    query.resetPaging()
    #expect(query.offset == 0)
  }
}
