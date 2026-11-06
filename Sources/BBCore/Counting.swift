//  Counting
//  "1 device", "3 devices": in one place.
//
//  A count with a noun beside it is one thing, so it is one function. Written by hand it
//  comes out as `"\(n) thing(s)"`, which reads as unfinished copy, or as a ternary on
//  `n == 1` repeated at every call site until one of them tests `> 1` and calls zero
//  things "0 thing".
//
//  In BBCore so the CLI, the migration's step summaries and the app all say it the same
//  way. The number is formatted for the current locale, which is right for a sentence a
//  person reads and wrong for one a client parses: an error message on the wire keeps its
//  digits as they are.

import Foundation

extension Int {

  /// The count and its noun, agreeing.
  ///
  /// The plural is the singular plus "s" unless it is given, which covers every noun this
  /// server counts except the irregular ones it passes in. The number is formatted, so a
  /// large count reads "1,024 messages" rather than "1024 messages".
  ///
  ///     2.counted("device")             // "2 devices"
  ///     1.counted("entry", "entries")   // "1 entry"
  public func counted(_ singular: String, _ plural: String? = nil) -> String {
    let noun = self == 1 ? singular : (plural ?? singular + "s")
    return "\(formatted(.number)) \(noun)"
  }
}
