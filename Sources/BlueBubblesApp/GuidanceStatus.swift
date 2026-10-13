//  GuidanceStatus
//  What the Guides page has read about this Mac, and the sentences it says about it.
//
//  Off the view because the sentences are the part that has to be right, and a decision
//  that lives on a `View` cannot be asserted: touching a SwiftUI `View` type from a test
//  process traps.

import Foundation

struct GuidanceStatus: Equatable {
  var privateAPI: Bool
  var helperConnected: Bool
  var pushConfigured: Bool
  /// Nil when the count could not be READ, which is not the same as zero.
  ///
  /// A contact index this server cannot open must not render "0 contacts indexed" on the
  /// row whose whole job is diagnosing "Messages show phone numbers instead of names": a
  /// confident zero there sends someone to re-index an address book that was never the
  /// problem.
  var contactsIndexed: Int?
  /// Whether the Contacts integration is switched on. Distinct from a count of nil: one is a
  /// decision somebody made, the other is a read that did not work.
  var contactsEnabled: Bool

  /// What the contacts row says under it. Four states, four sentences: an unreadable count
  /// must not render as "0 contacts indexed", which reads as a fact about the address book
  /// rather than about this server's access to it.
  static func contactsDetail(for indexed: Int?, enabled: Bool = true) -> String {
    // Checked FIRST: with the integration off the count cannot be read at all, so every
    // other branch here would describe the failure rather than the switch that caused it.
    guard enabled else { return "the Contacts integration is switched off" }
    guard let indexed else { return "the contact index could not be read" }
    // Zero is a real, reportable state (the index was read and is empty) and it is what
    // this row exists to send someone to fix.
    return indexed == 0 ? "no contacts indexed yet" : "\(indexed.counted("contact")) indexed"
  }
}
