//  PageCursorTests
//  Paging over a set the database counts, which can shrink underneath the page on screen.
//
//  The clamp is the load-bearing rule: an offset past the end answers with no rows, and an
//  empty table reads as a failed read rather than as a page that is no longer there. Contacts
//  and the Audit Log share it through `PageCursor`.

import Testing

@testable import BlueBubblesApp

@Suite("Page cursor")
struct PageCursorTests {

  @Test("Moving never goes before the first row")
  func moving() {
    var cursor = PageCursor(limit: 100)
    cursor.move(to: -50)
    #expect(cursor.offset == 0)
    #expect(!cursor.hasPrevious)

    cursor.next()
    #expect(cursor.offset == 100)
    #expect(cursor.hasPrevious)
    cursor.previous()
    cursor.previous()
    #expect(cursor.offset == 0)
  }

  @Test("There is a next page only while rows remain past this one")
  func hasNext() {
    let cursor = PageCursor(limit: 100)
    #expect(cursor.hasNext(total: 150))
    #expect(!cursor.hasNext(total: 100))
    #expect(!cursor.hasNext(total: 0))
  }

  @Test("A pager has something to do only past one page")
  func isPaged() {
    let cursor = PageCursor(limit: 100)
    #expect(!cursor.isPaged(total: 100))
    #expect(cursor.isPaged(total: 101))
  }

  @Test("A set that shrinks pulls the offset back to its last page")
  func clamp() {
    var cursor = PageCursor(limit: 100)
    cursor.move(to: 800)
    // Page 9 of 400 is past the end once the set is 150.
    let shrank = cursor.clamp(toTotal: 150)
    #expect(shrank)
    #expect(cursor.offset == 100)
    let again = cursor.clamp(toTotal: 150)
    #expect(!again, "already in range, so nothing to re-read")
    // Exactly one page's worth belongs on the first page, not on an empty second one.
    let onePage = cursor.clamp(toTotal: 100)
    #expect(onePage)
    #expect(cursor.offset == 0)
  }

  @Test("An empty set belongs on the first page")
  func clampToEmpty() {
    var cursor = PageCursor(limit: 100)
    cursor.move(to: 300)
    let moved = cursor.clamp(toTotal: 0)
    #expect(moved)
    #expect(cursor.offset == 0)
  }

  @Test("A set that grows leaves the offset alone")
  func clampWhenGrowing() {
    var cursor = PageCursor(limit: 100)
    cursor.move(to: 200)
    let moved = cursor.clamp(toTotal: 5_000)
    #expect(!moved)
    #expect(cursor.offset == 200)
  }

  @Test("Resetting goes back to the first page")
  func reset() {
    var cursor = PageCursor(limit: 100)
    cursor.move(to: 200)
    cursor.reset()
    #expect(cursor.offset == 0)
  }

  @Test("The summary counts from one, and names the noun when there is nothing")
  func summary() {
    var cursor = PageCursor(limit: 100)
    cursor.move(to: 100)
    #expect(cursor.summary(showing: 100, total: 250, noun: "record") == "Showing 101-200 of 250")
    #expect(cursor.summary(showing: 50, total: 150, noun: "record") == "Showing 101-150 of 150")
    #expect(cursor.summary(showing: 0, total: 0, noun: "record") == "0 records")
    #expect(cursor.summary(showing: 0, total: 0, noun: "contact") == "0 contacts")
  }

  @Test("Both paged queries start on the first page of a hundred")
  @MainActor
  func queries() {
    #expect(ContactsQuery().cursor == PageCursor(limit: 100))
    #expect(AuditLogQuery().cursor == PageCursor(limit: 100))
  }
}
