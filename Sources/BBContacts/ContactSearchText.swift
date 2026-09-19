//  ContactSearchText
//  The one spelling of "what a contact matches", shared by the index that stores it and the
//  page that types into it.
//
//  Search used to run in memory: every contact was read, flattened into a haystack string,
//  and scanned per keystroke. That is what forced the page to load the whole address book,
//  which is the memory cost, and it is why the read was capped — a cap that then disagreed
//  with the interface's own clamp, so an address book over a thousand contacts was silently
//  truncated with nothing on screen saying so.
//
//  Stored instead, folded once when the contact is indexed, so the filter is a SQL predicate
//  and a page is a page. The fold has to be IDENTICAL on both sides or a query matches a
//  haystack it should not, which is why it lives here rather than being written twice.
//
//  Matching is substring, not prefix: people search for a fragment of a surname or the middle
//  of a number, and that was the behaviour before this moved.

import BBCore
import Foundation

public enum ContactSearchText {

  /// One case-folding, used for both sides of every comparison.
  ///
  /// `.caseInsensitive` folding rather than `lowercased()`: SQLite's own `lower()` is ASCII
  /// only, so a name like "Ångström" would fold one way in Swift and another in SQL. Folding
  /// both sides here, in Swift, is what keeps the two in step — the stored column is already
  /// folded, and the query is folded to match it.
  public static func fold(_ text: String) -> String {
    text.folding(options: .caseInsensitive, locale: .current)
  }

  /// Everything about a contact that a search should find, folded.
  ///
  /// Includes the FORMATTED addresses as well as the stored ones, because the table shows the
  /// formatted spelling: a row displaying "(555) 010-1234" has to be findable by typing
  /// "(555) 010", and the stored address is either the raw entry or a stripped lookup key.
  /// That is why `AddressFormatting` had to move into `BBCore`.
  public static func haystack(
    name: String?, firstName: String?, lastName: String?, nickname: String?,
    phoneNumbers: [String], emailAddresses: [String]
  ) -> String {
    let display =
      name
      ?? [firstName, lastName]
      .compactMap { $0 }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)

    let parts =
      [
        display, firstName, lastName, nickname,
        AddressFormatting.list(phoneNumbers, areEmails: false),
        AddressFormatting.list(emailAddresses, areEmails: true),
      ].compactMap { $0 } + phoneNumbers + emailAddresses
      // The STRIPPED forms too, so typing bare digits finds a number stored as
      // "+1 (555) 010-1234". This is the way most people type a phone number into a search
      // box, and neither the raw spelling nor the formatted one contains it — the in-memory
      // search this replaces could not do it either.
      + phoneNumbers.map(AddressNormalizer.strip)
      + emailAddresses.map(AddressNormalizer.strip)

    return fold(parts.joined(separator: " "))
  }

  /// The haystack for a record.
  public static func haystack(for contact: ContactRecord) -> String {
    haystack(
      name: contact.displayName, firstName: contact.firstName, lastName: contact.lastName,
      nickname: contact.nickname, phoneNumbers: contact.phoneNumbers,
      emailAddresses: contact.emailAddresses
    )
  }

  /// The `LIKE` pattern for a typed query, or nil when the query matches everything.
  ///
  /// Escaped, with `\` as the escape character: a query containing `%` or `_` is a person
  /// looking for those characters, not a wildcard. Unescaped, a bare `%` matched every
  /// contact and read as search being broken.
  public static func pattern(for query: String) -> String? {
    let folded = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !folded.isEmpty else { return nil }
    let escaped =
      folded
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    return "%\(escaped)%"
  }
}
