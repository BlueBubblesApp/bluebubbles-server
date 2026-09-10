//  Counting
//  "1 device", "3 devices": in one place.
//
//  There were three spellings of this. Half the app wrote `"\(n) thing(s)"`, which reads as
//  unfinished copy; the other half wrote `"\(n) thing\(n == 1 ? "" : "s")"`, which is right
//  and was repeated at nine call sites; and one row spelled the verb out too. A count with a
//  noun beside it is one thing, so it is one function.
//
//  Not a View, so it can be tested; see `CountingTests`.

import Foundation

extension Int {

  /// The count and its noun, agreeing.
  ///
  /// The plural is the singular plus "s" unless it is given, which covers everything in this
  /// app except the irregular nouns it does not have. The number is formatted, so a large
  /// count reads "1,024 messages" rather than "1024 messages".
  ///
  ///     2.counted("device")             // "2 devices"
  ///     1.counted("entry", "entries")   // "1 entry"
  func counted(_ singular: String, _ plural: String? = nil) -> String {
    let noun = self == 1 ? singular : (plural ?? singular + "s")
    return "\(formatted(.number)) \(noun)"
  }
}
