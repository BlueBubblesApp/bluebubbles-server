//  SearchDraftTests
//  A database-paged page reads its table again when its query changes, so typing must not
//  change the query: only a pause, Return or clearing does.
//
//  The Audit Log waited for a pause and Contacts queried the index on every keystroke. Both
//  hold a `SearchDraft` now; the Audit Log's own tests cover its query, and this covers the
//  draft and the Contacts query that used to skip it.

import Testing

@testable import BlueBubblesApp

@Suite("Search drafts")
@MainActor
struct SearchDraftTests {

  @Test("Typing is not searching; committing is, once")
  func commitIsTheSearch() {
    var search = SearchDraft()
    search.text = "ali"
    #expect(search.committed == "")
    let first = search.commit()
    #expect(first)
    #expect(search.committed == "ali")
    let again = search.commit()
    #expect(!again, "committing the same text again is not a change")
  }

  @Test("Clearing empties the field and the search at once")
  func clearIsImmediate() {
    var search = SearchDraft()
    search.text = "ali"
    search.commit()
    search.text = "alic"
    search.clear()
    #expect(search.text == "")
    #expect(search.committed == "")
  }

  @Test("Typing in the contacts search does not move the reload key until it is committed")
  func contactsQueryWaitsForTheCommit() {
    let query = ContactsQuery()
    let before = query.reloadKey
    query.search.text = "203"
    #expect(query.reloadKey == before)
    query.search.commit()
    #expect(query.reloadKey != before)
  }
}
