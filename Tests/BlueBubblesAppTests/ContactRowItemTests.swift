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

@Suite("Contact row items")
@MainActor
struct ContactRowItemTests {

  /// The four strings the table shows, built once when the row is built.
  ///
  /// This suite used to cover filtering and sorting too. Both moved into SQL
  /// (`ContactIndex.search`), because filtering in memory is what forced the whole address
  /// book to be in memory; `ContactSearchTests` covers them there, against the database that
  /// now does them. What is left is the flattening, which is still the app's job.
  @Test("A record is flattened into the columns the table shows")
  func flattensIntoColumns() {
    let row = ContactRowItem(
      ContactRecord(
        id: "1", source: .macOS, firstName: "Ada", lastName: "Lovelace",
        phoneNumbers: ["2025550143"], emailAddresses: ["someone@example.com"]))

    #expect(row.name == "Ada Lovelace")
    #expect(row.emails == "someone@example.com")
    // Formatted for display, which is why `AddressFormatting` is shared with the index: the
    // stored haystack has to contain the spelling the person can see.
    #expect(row.phones.contains("202"))
  }

  /// A record with a display name uses it rather than re-joining the parts, which is how
  /// Contacts renders a company or a single-name entry.
  @Test("A display name wins over the name parts")
  func displayNameWins() {
    let row = ContactRowItem(
      ContactRecord(
        id: "1", source: .macOS, firstName: "Ada", lastName: "Lovelace",
        displayName: "Analytical Engines Ltd"))
    #expect(row.name == "Analytical Engines Ltd")
  }

  /// The Account column falls back to the source for a row indexed before accounts were
  /// recorded, and sorting that column orders by what it shows.
  @Test("The account label falls back to the source")
  func accountFallsBackToSource() {
    let row = ContactRowItem(ContactRecord(id: "1", source: .macOS, firstName: "Ada"))
    #expect(row.account == nil)
    #expect(row.accountLabel == row.source)
    #expect(row.source == "Address Book")
  }
}
