//  LooseBool
//  A boolean written as text, read one way everywhere.
//
//  A setting from the command line, a field in a service's form, a query parameter, a
//  handshake flag and a value from the Electron server's config all arrive as strings, and
//  six readers disagreed about which strings were true: one took only `"true"`, so
//  `--set …=1` switched a service's flag off while the same `1` switched a core setting on.

import Foundation

extension Bool {
  /// `"1"`, `"true"` and `"yes"` are true and `"0"`, `"false"` and `"no"` false, in any case
  /// and with surrounding whitespace ignored. Nil for anything else, so a caller decides
  /// what an unreadable value means rather than having it decided here.
  public init?(loose raw: String) {
    switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
    case "1", "true", "yes": self = true
    case "0", "false", "no": self = false
    default: return nil
    }
  }
}
