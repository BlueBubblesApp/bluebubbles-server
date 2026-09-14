//  ContactFiltering
//  Which contacts the table shows, for a typed query, and in what order.
//
//  Off the view for the reason `LogFiltering` is: touching a SwiftUI `View` type from a test
//  process traps, so a decision that deserves a test cannot live on the view that uses it.
//
//  It deserves one because it is the most expensive thing the app does. `ContactRowItem`'s
//  every property was COMPUTED, so a sort rebuilt each row's name -- an array, a compactMap, a
//  join and a trim -- on each of about 61,000 comparisons, and a search rebuilt name, phones
//  and emails per candidate. Measured at the 5,000-row cap: 21.9ms to filter, 94ms to sort,
//  115ms for a pass, and the page made two passes per keystroke. On a 2012-2017 Intel Mac that
//  is most of a second between a letter and the letter appearing.
//
//  The properties are stored now, computed once when the row is built, and this type exists so
//  the query folding is done once per keystroke rather than once per row.

import BBContacts
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

  /// Everything searchable, case-folded once.
  ///
  /// Searches the RAW addresses as well as the formatted ones, so typing a bare "5550101234"
  /// still finds a number displayed as "(555) 010-1234".
  ///
  /// Folded rather than compared with `localizedCaseInsensitiveContains`, which case-folds
  /// both sides on every call: the same case-insensitive answer, with the row's side of the
  /// work done once when the row is built instead of once per keystroke per row.
  let searchHaystack: String

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
    let source =
      switch record.source {
      case .macOS: "Address Book"
      case .local: "Local"
      }

    self.name = name
    self.phones = phones
    self.emails = emails
    self.account = record.account?.label
    self.source = source
    self.accountLabel = record.account?.label ?? source
    self.searchHaystack = ContactFiltering.fold(
      ([name, phones, emails] + record.phoneNumbers + record.emailAddresses)
        .joined(separator: " "))
  }
}

enum ContactFiltering {

  /// One case-folding, used for both sides of every comparison.
  static func fold(_ text: String) -> String {
    text.folding(options: .caseInsensitive, locale: .current)
  }

  /// Rows matching `search`, in `sortOrder`.
  ///
  /// An empty query returns everything rather than nothing, which is the direction that
  /// cannot hide a person's contacts from them.
  static func visible(
    _ rows: [ContactRowItem],
    search: String,
    sortOrder: [KeyPathComparator<ContactRowItem>]
  ) -> [ContactRowItem] {
    let matching = matches(rows, search: search)
    return matching.sorted(using: sortOrder)
  }

  /// The filter alone, unsorted.
  ///
  /// Separate because the toolbar's count needs how MANY match and not in what order, and
  /// sorting is four times the cost of filtering. That count was the one call site still
  /// running a second full pass -- sort included -- on every keystroke.
  static func matches(_ rows: [ContactRowItem], search: String) -> [ContactRowItem] {
    let query = fold(search.trimmingCharacters(in: .whitespaces))
    guard !query.isEmpty else { return rows }
    return rows.filter { $0.searchHaystack.contains(query) }
  }
}
