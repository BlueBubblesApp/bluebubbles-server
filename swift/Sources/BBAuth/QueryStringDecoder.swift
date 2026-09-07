//  QueryStringDecoder
//  One percent-decoding, shared by the HTTP API and the socket handshake.
//
//  Passwords arrive in a URL, and this is where they have historically been corrupted. Three
//  distinct bugs, all of which look like "the server rejected my correct password":
//
//  1. **Double decoding.** The current server parses the socket handshake query — which
//     engine.io has ALREADY percent-decoded — and then calls `decodeURI` on the result. A
//     password containing a literal `%` followed by two hex digits is decoded twice: the
//     client correctly sends `a%2520b` for the password `a%20b`, and the server ends up with
//     `a b`. The user's password is now unusable and nothing explains why.
//
//  2. **`+` handled inconsistently.** Node's `querystring.parse` turns `a+b` into `a b`;
//     `decodeURI` does not. So the HTTP and socket paths disagreed with each other about a
//     password containing a space.
//
//  3. **`decodeURI` throws.** A malformed sequence — a bare `%`, which is a perfectly legal
//     password character — raises a `URIError` rather than returning the input.
//
//  The rule here is deliberately the one Koa applies to `ctx.query`, because that is what
//  every shipped client was written against:
//
//    - `+` becomes a space. A client that encoded a space as `+` keeps working, and a
//      password containing a literal `+` is sent as `%2B` — which is what percent-encoding
//      is for, and what those clients already do.
//    - Percent sequences are decoded EXACTLY ONCE.
//    - A malformed sequence yields the input unchanged rather than throwing or emptying.
//
//  Both surfaces call this, so a password that works over HTTP works over the socket by
//  construction rather than by coincidence.
//
//  See `.claude/docs/decisions.md`.

import Foundation

public enum QueryStringDecoder {

  /// Parses a raw query string — everything after `?`, without the `?`.
  ///
  /// Deliberately parses the RAW string rather than taking an already-parsed dictionary.
  /// Taking a parsed one is how the double decode happened: the caller cannot tell whether
  /// what it was handed has been decoded already, so it decodes defensively and corrupts
  /// anything that was already correct.
  public static func parse(_ rawQuery: String) -> [String: String] {
    var result: [String: String] = [:]
    guard !rawQuery.isEmpty else { return result }

    for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
      guard let separator = pair.firstIndex(of: "=") else {
        // A valueless parameter — `?pretty`. Present with an empty value, which is
        // what presence checks look for.
        result[decode(String(pair))] = ""
        continue
      }
      let key = decode(String(pair[pair.startIndex..<separator]))
      let value = decode(String(pair[pair.index(after: separator)...]))
      // Last wins, matching Koa. A repeated `?password=` is not something clients do,
      // but the behaviour should not be surprising if one ever does.
      result[key] = value
    }
    return result
  }

  /// Decodes one component: `+` to space, then a single percent-decoding pass.
  ///
  /// Never throws and never returns nil. A password is arbitrary bytes chosen by a person,
  /// and refusing to decode one is indistinguishable to them from refusing the password.
  public static func decode(_ component: String) -> String {
    // `+` first. Doing it after percent-decoding would also convert a `+` that the client
    // correctly encoded as `%2B`, which would silently corrupt a password containing one.
    let spaced = component.replacingOccurrences(of: "+", with: " ")

    // `removingPercentEncoding` returns nil for an invalid sequence — a bare `%`, or `%`
    // followed by non-hex. Both are legal in a password, so the input stands.
    return spaced.removingPercentEncoding ?? spaced
  }
}
