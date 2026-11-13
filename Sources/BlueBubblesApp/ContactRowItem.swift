//  ContactRowItem
//  One row of the contacts table: a record flattened into the four strings it shows.
//
//  Off the view for the reason `LogFiltering` is: touching a SwiftUI `View` type from a test
//  process traps, so a decision that deserves a test cannot live on the view that uses it.
//
//  **The filtering and sorting that used to live here are gone, into SQL.** They were the most
//  expensive thing the app did: measured at the old 5,000-row cap, 21.9ms to filter and 94ms
//  to sort, twice per keystroke — but the real cost was upstream, because filtering in memory
//  means every contact has to BE in memory. `ContactIndex.search` does both now, and the page
//  reads one page. What is left here is the flattening, which is per displayed row and has to
//  happen somewhere.
//
//  The properties stay STORED rather than computed: a table re-reads them per redraw, and they
//  were rebuilt on each of about 61,000 comparisons before they were stored.

import BBContacts
import BBCore
import Foundation

/// A flattened row.
///
/// `ContactRecord` is `Identifiable`, so this exists purely to turn a record into the four
/// strings the table shows. All of them are STORED: see the file header for what computing
/// them cost.
struct ContactRowItem: Identifiable {
  let record: ContactRecord
  var id: String { record.id }

  let name: String
  let phones: String
  let emails: String
  /// The account label, once the contact has been re-indexed since accounts were recorded.
  ///
  /// Read from the record rather than from a serialized dictionary: an absent key is
  /// silent, an absent property does not compile.
  let account: String?
  /// Shown only as a fallback, for rows indexed before accounts were recorded.
  let source: String
  /// What the Account column shows, and what sorting it orders by.
  let accountLabel: String

  init(_ record: ContactRecord) {
    self.record = record
    let name =
      record.displayName
      ?? [record.firstName, record.lastName]
      .compactMap { $0 }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    let phones = AddressFormatting.list(record.phoneNumbers, areEmails: false)
    let emails = AddressFormatting.list(record.emailAddresses, areEmails: true)
    // The index spells this too, for the query that groups by it; see `ContactSource.label`.
    let source = record.source.label

    self.name = name
    self.phones = phones
    self.emails = emails
    self.account = record.account?.label
    self.source = source
    self.accountLabel = record.account?.label ?? source
  }
}
