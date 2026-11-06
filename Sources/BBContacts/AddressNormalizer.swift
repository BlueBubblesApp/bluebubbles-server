//  AddressNormalizer
//  The one spelling of an address the contact index stores and probes with.
//
//  Its own file because the rule is read on its own: an ingestor normalises what it writes and
//  a lookup normalises what it asks, and both have to agree without either opening the index
//  (`ContactIndex.swift`). The matching rule it serves is explained there.

import Foundation

public enum AddressNormalizer {

  /// Strips everything that is not `[a-zA-Z0-9_]`.
  ///
  /// Matches the alphaNumericRegex in findContact exactly, underscore included. Note it
  /// does NOT lowercase: the reference does not either, so `Bob@example.com` and `bob@example.com`
  /// are different keys today. We lowercase emails at INDEX time instead (below), which
  /// makes matching strictly better without changing what a correct match returns.
  public static func strip(_ address: String) -> String {
    String(
      address.unicodeScalars.filter { scalar in
        (scalar >= "a" && scalar <= "z")
          || (scalar >= "A" && scalar <= "Z")
          || (scalar >= "0" && scalar <= "9")
          || scalar == "_"
      }.map(Character.init))
  }

  public static func classify(_ address: String) -> AddressKind {
    address.contains("@") ? .email : .phone
  }

  /// The stored key. Emails lowercase; phone numbers keep their digits as-is.
  ///
  /// An email is stripped like a number, and that is a trade made on purpose: it is what lets
  /// `personname@example.com` find a card that says `Person.Name@Example.com`, which for
  /// Gmail, where dots do not count, is the same mailbox. The cost is that two genuinely
  /// different addresses differing only in punctuation share a key. The first is common and
  /// the second is rare, and the reference matches the same way, so the lookup a client sees
  /// is the one it always has. `lookupStillNormalizes` holds it.
  public static func normalize(_ address: String, kind: AddressKind) -> String {
    let stripped = strip(address)
    return kind == .email ? stripped.lowercased() : stripped
  }

  public static func reversed(_ normalized: String) -> String {
    String(normalized.reversed())
  }
}
