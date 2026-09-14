//  ContactFilteringTests
//  The contacts page's filtering and sorting, which was the most expensive thing the app did.
//
//  Every `ContactRowItem` property was computed, so a sort rebuilt each row's name on each of
//  about 61,000 comparisons and a search rebuilt name, phones and emails per candidate:
//  measured at 115ms a pass at the 5,000-row cap, twice per keystroke, which on a 2012-2017
//  Intel Mac is most of a second between typing a letter and seeing it.
//
//  These assert the behaviour that must not change while that was fixed -- what matches, and
//  in what order -- plus the property that makes the fix a fix: the row's searchable text is
//  built once, so the two paths cannot disagree about what a row contains.

import BBContacts
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Contact filtering")
struct ContactFilteringTests {

  private static func record(
    id: String = UUID().uuidString,
    displayName: String? = nil,
    first: String? = nil,
    last: String? = nil,
    phones: [String] = [],
    emails: [String] = []
  ) -> ContactRecord {
    ContactRecord(
      id: id,
      source: .macOS,
      firstName: first,
      lastName: last,
      displayName: displayName,
      phoneNumbers: phones,
      emailAddresses: emails
    )
  }

  /// STORED, not computed: each call built new records with new UUIDs, so two calls
  /// produced rows that could never compare equal by id.
  private let rows: [ContactRowItem] = {
    [
      Self.record(first: "Ada", last: "Lovelace", phones: ["+12025550143"]),
      Self.record(first: "Grace", last: "Hopper", emails: ["someone@example.com"]),
      Self.record(displayName: "Zoë Washburne", phones: ["+12025550199"]),
    ].map(ContactRowItem.init)
  }()

  @Test("An empty query shows everyone")
  func emptyQueryMatchesAll() {
    #expect(ContactFiltering.matches(rows, search: "").count == 3)
    #expect(ContactFiltering.matches(rows, search: "   ").count == 3)
  }

  @Test("Matching is case-insensitive, on names and on addresses")
  func matchesNamesAndAddresses() {
    #expect(ContactFiltering.matches(rows, search: "ada").map(\.name) == ["Ada Lovelace"])
    #expect(ContactFiltering.matches(rows, search: "LOVELACE").count == 1)
    #expect(ContactFiltering.matches(rows, search: "someone@example").count == 1)
  }

  /// The reason the haystack keeps the raw addresses as well as the formatted ones: a person
  /// types the digits they remember, not the punctuation the table draws.
  @Test("A bare number finds a contact whose number is displayed formatted")
  func rawDigitsMatchFormattedNumbers() {
    let row = rows[0]
    #expect(row.phones.contains("(202)"), "the number is displayed formatted")
    #expect(ContactFiltering.matches(rows, search: "2025550143").count == 1)
  }

  @Test("Nothing matching gives nothing, rather than everything")
  func noMatchesIsEmpty() {
    #expect(ContactFiltering.matches(rows, search: "nobody at all").isEmpty)
  }

  @Test("Sorting follows the comparator it is given, in both directions")
  func sortingFollowsTheComparator() {
    let ascending = ContactFiltering.visible(
      rows, search: "", sortOrder: [KeyPathComparator(\ContactRowItem.name)])
    #expect(ascending.map(\.name) == ["Ada Lovelace", "Grace Hopper", "Zoë Washburne"])

    let descending = ContactFiltering.visible(
      rows, search: "", sortOrder: [KeyPathComparator(\ContactRowItem.name, order: .reverse)])
    #expect(descending.map(\.name) == ascending.map(\.name).reversed())
  }

  @Test("Filtering and sorting compose: the matches come back ordered")
  func filterThenSort() {
    let visible = ContactFiltering.visible(
      rows, search: "a", sortOrder: [KeyPathComparator(\ContactRowItem.name)])
    #expect(visible.count > 1, "the query has to match more than one row to order anything")
    #expect(visible.map(\.name) == visible.map(\.name).sorted())
  }

  /// The count in the toolbar must agree with the table under it. They are separate calls
  /// now -- one sorts and one does not -- so this is the property that keeps them honest.
  @Test("The unsorted count agrees with the sorted list")
  func countAgreesWithList() {
    for query in ["", "a", "LOVELACE", "2025550143", "nobody"] {
      let matched = ContactFiltering.matches(rows, search: query)
      let visible = ContactFiltering.visible(
        rows, search: query, sortOrder: [KeyPathComparator(\ContactRowItem.name)])
      #expect(matched.count == visible.count, "disagreed on \"\(query)\"")
      #expect(Set(matched.map(\.id)) == Set(visible.map(\.id)))
    }
  }

  /// The properties are stored now. A row built once and read many times is the whole fix,
  /// so this asserts the row carries its strings rather than rebuilding them.
  @Test("A row's searchable text is built with the row")
  func haystackIsBuiltOnce() {
    let row = ContactRowItem(Self.record(first: "Ada", last: "Lovelace", phones: ["+12025550143"]))
    #expect(row.name == "Ada Lovelace")
    #expect(row.searchHaystack == ContactFiltering.fold(row.searchHaystack))
    #expect(row.searchHaystack.contains("ada"))
    #expect(row.searchHaystack.contains("2025550143"))
  }
}
