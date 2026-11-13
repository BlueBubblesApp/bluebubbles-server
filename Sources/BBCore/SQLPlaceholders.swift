//  SQLPlaceholders
//  The `?, ?, ?` an `IN (…)` list or a `VALUES` row binds into.
//
//  One spelling, because the list has to agree with the arguments bound beside it and a
//  hand-written copy is where the two drift: a count taken from the wrong collection binds
//  too few parameters, and SQLite reports that at run time, on whichever route reached it.
//  `SQLPlaceholderPolicyTests` fails the build on a hand-written list anywhere in the tree.
//
//  An empty list gives the empty string, so `IN ()` reaches SQLite, which accepts it and
//  matches nothing. Callers that need a different answer for no values guard before they
//  get here, and every one of them already does.

/// Bound-parameter lists for hand-built SQL.
public enum SQLPlaceholders {

  /// `count` parameters, comma-separated: `?, ?, ?`.
  public static func list(_ count: Int) -> String {
    Array(repeating: "?", count: max(count, 0)).joined(separator: ", ")
  }

  /// `count` parenthesised rows of `width` parameters each: `(?, ?), (?, ?)`. For a
  /// `VALUES` table built in a CTE, where each row is several bound values.
  public static func rows(_ count: Int, width: Int) -> String {
    let row = "(\(list(width)))"
    return Array(repeating: row, count: max(count, 0)).joined(separator: ", ")
  }
}
