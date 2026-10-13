//  MessageSearchTerm
//  Turning the `LIKE` term a client sends into something FTS5 can match, or admitting it
//  cannot be turned into one.
//
//  Clients send `message.text LIKE ?` with a term like `%pizza%`. The index speaks a different
//  language: whole tokens, not substrings. The translation between them is not lossless, and
//  the honest thing is to say exactly where, because these are differences a user can SEE.
//
//  WHAT CHANGES, AND IN WHICH DIRECTION
//
//  **Narrower: a fragment in the MIDDLE of a word.** `%harb%` finds "harbour" and `%bour%`
//  does not. An inverted index records where tokens START, so a trailing wildcard maps exactly
//  onto FTS5's own prefix operator and a leading one has nothing to map onto. This is the
//  trade a token index is.
//
//  **And a whole script, not just a fragment.** `unicode61` breaks on anything that is not a
//  letter or a digit, and every character of Chinese, Japanese or Thai is a letter — so an
//  entire sentence in one of them is ONE token, and a search for a word inside it matches
//  nothing. Measured: `明天我们去吃晚饭好吗` is a single token, `晚饭` finds it not at all.
//
//  **Neither of those costs a result, because the CALLER falls back.** An empty answer from
//  the index is not treated as "no results": `MessageRepository.resolvingSearch` sends the
//  term back down the `LIKE` path, so the worst case is the behaviour the server had before
//  this existed. Read the two paragraphs above as "the index does not help here", not as
//  "the search finds less". The distinction is the whole reason this translation is allowed
//  to refuse things.
//
//  `%term` with no trailing wildcard — "ends with" — is refused outright rather than answered
//  narrowly, because an exact-token match would answer a different question while looking like
//  a working search that found nothing. The caller falls back to `LIKE`.
//
//  **Broader: more than one word.** `LIKE '%see you%'` requires the words to be adjacent.
//  `detail='none'` stores no token positions — deliberately; it is what keeps the index from
//  being reconstructable back into sentences — so adjacency cannot be expressed and the
//  closest available match is "contains both words". A search for `see you` will therefore
//  also find a message containing "see" and "you" far apart.
//
//  That second one is a real divergence and it is accepted for now, for three reasons: the
//  alternative today is finding NOTHING, which is the defect this exists to fix; the results
//  are a superset rather than a different set, so nothing a user expected to find is missing;
//  and the exact fix is known and costed — re-check the candidates against their decoded text,
//  at 0.015 ms each over a few hundred rows. See `docs/SEARCH.md`.
//
//  **Never broader for an ANCHORED term.** `hello%` is "starts with" and `hello` with no
//  wildcard is "is exactly": that is what `LIKE` means for them, on the reference as here,
//  because `/message/query` hands the client's `where` statement to SQLite as written. A
//  token index cannot say where a token sits, so its answer to either is "contains a word
//  starting with hello" (or "contains the word hello"), and a union with that would return
//  "well, hello there" for a search that asked for messages beginning with "hello". So an
//  anchored term's matches are CANDIDATES: `Anchoring` says what the term actually asks, and
//  `MessageRepository.resolvingSearch` keeps only the candidates whose text satisfies it.
//  The cost is the re-check `docs/SEARCH.md` costs at 0.015 ms a candidate, paid only by the
//  anchored forms.
//
//  The reference's Private API path does treat every term as "contains"
//  (`messageRouter.ts`, which strips the wildcards and asks Spotlight for a `contains`
//  match), but that path runs only when its helper is connected and is a different search;
//  the `where` statement a client wrote is the contract this server answers.
//
//  NOTHING HERE IS TRUSTED INPUT. The term is whatever a client put in a JSON body, and FTS5
//  MATCH is a query language with operators (`AND`, `OR`, `NOT`, `NEAR`, `*`, `^`, `:`, `-`,
//  parentheses). Every token is emitted as a quoted string so none of it can be read as
//  syntax.

import Foundation

/// A client's `LIKE` term, translated for the index.
public enum MessageSearchTerm: Sendable, Equatable {

  /// An FTS5 MATCH expression, ready to bind.
  case match(String)

  /// The term cannot be expressed against a token index, so the caller must use `LIKE`.
  ///
  /// Not a failure: a fallback that finds what it always found. The reason is carried so a
  /// log line can say which kind of term is still going the slow way.
  case notExpressible(reason: Reason)

  public enum Reason: String, Sendable, Equatable {
    /// `%piz%za%` — a wildcard in the middle of the term. Neither a token match nor a
    /// prefix match can express it.
    case interiorWildcard
    /// `%term` — "ends with". An inverted index is built on where tokens START.
    case endsWith
    /// `_` is a `LIKE` single-character wildcard with no FTS5 equivalent.
    case singleCharacterWildcard
    /// Nothing but wildcards and punctuation: no token to look up.
    case noSearchableTokens
  }

  /// Translates a `LIKE` term.
  ///
  /// - Parameter term: exactly what the client sent, wildcards included.
  public static func from(likeTerm term: String) -> MessageSearchTerm {
    // `_` matches any single character in `LIKE`. FTS5 has no equivalent, and treating it as
    // a literal underscore would silently answer a different question.
    if term.contains("_") { return .notExpressible(reason: .singleCharacterWildcard) }

    // The wildcards a client actually sends sit at the ends: `%pizza%` is "contains". Strip
    // them, and remember whether the trailing one was there — it is the only one an index
    // can honour, as a prefix match.
    var body = Substring(term)
    let hadLeading = body.hasPrefix("%")
    while body.hasPrefix("%") { body = body.dropFirst() }
    let hadTrailing = body.hasSuffix("%")
    while body.hasSuffix("%") { body = body.dropLast() }

    // A `%` that survived the trim was in the middle: `%piz%za%`. Neither the index nor a
    // prefix operator can express that.
    if body.contains("%") { return .notExpressible(reason: .interiorWildcard) }

    let tokens = tokenize(String(body))
    guard !tokens.isEmpty else { return .notExpressible(reason: .noSearchableTokens) }

    // `%term` with no trailing wildcard is "ends with", which an inverted index cannot
    // answer at all. Emitting an exact-token match for it would answer a different question
    // and look like a working search returning nothing.
    //
    // `%term%` and `term%` are both looked up as a PREFIX match, and that is the divergence
    // to know about: `%harb%` finds "harbour" and `%bour%` does not, because "bour" begins
    // no token. The index is therefore narrower than `LIKE` for a fragment in the middle of
    // a word, but the ANSWER is not, because an empty result sends the term back to
    // `LIKE`. `term%` and a bare `term` are anchored, so what the index finds for them is
    // re-checked against `Anchoring` before it is used. See the header.
    if hadLeading, !hadTrailing { return .notExpressible(reason: .endsWith) }

    // Quoted, always. A bare `AND`, `NOT`, `NEAR`, `-`, `^`, `:` or `(` in a client's term
    // would otherwise be read as FTS5 syntax rather than as a word to look for, which is
    // either a wrong answer or a syntax error depending on where it lands.
    //
    // The prefix operator goes OUTSIDE the quotes, which is where FTS5 expects it, and only
    // on the last token: `%see you%` is "see" and a word starting with "you", exactly as
    // `LIKE` would have it.
    let quoted = tokens.enumerated().map { index, token -> String in
      let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
      let isLast = index == tokens.count - 1
      return hadTrailing && isLast ? "\"\(escaped)\"*" : "\"\(escaped)\""
    }

    // AND, not a phrase: `detail='none'` cannot answer adjacency. See the header.
    return .match(quoted.joined(separator: " AND "))
  }

  /// What a `LIKE` term asks of the WHOLE text, where the index can only answer for tokens.
  ///
  /// `LIKE`'s own rules, transcribed: SQLite's `LIKE` ignores case for ASCII letters only,
  /// so `Hello%` matches "hello there" and `É` does not match `é`. A wider fold here would
  /// return rows the column match beside it would not.
  public enum Anchoring: Sendable, Equatable {
    /// `term%`: the text begins with `term`.
    case prefix(String)
    /// `term`, no wildcard: the text is `term`.
    case exact(String)

    /// Whether `text` is one `LIKE` would match.
    public func admits(_ text: String) -> Bool {
      switch self {
      case .prefix(let body):
        Self.folded(text).starts(with: Self.folded(body))
      case .exact(let body):
        Self.folded(text) == Self.folded(body)
      }
    }

    /// ASCII letters lowered, everything else as it is: `LIKE`'s case rule.
    private static func folded(_ text: String) -> [Unicode.Scalar] {
      text.unicodeScalars.map { scalar in
        guard ("A"..."Z").contains(scalar), let lower = Unicode.Scalar(scalar.value + 32) else {
          return scalar
        }
        return lower
      }
    }
  }

  /// The anchoring of a `LIKE` term, or nil when it is unanchored at the start (`%term%`,
  /// `%term`) and the index's answer needs no re-check.
  ///
  /// Only meaningful for a term `from(likeTerm:)` translated; one it refused never reaches
  /// the index, so whatever this says about it is unused.
  public static func anchoring(ofLikeTerm term: String) -> Anchoring? {
    guard !term.hasPrefix("%") else { return nil }
    var body = Substring(term)
    let hadTrailing = body.hasSuffix("%")
    while body.hasSuffix("%") { body = body.dropLast() }
    return hadTrailing ? .prefix(String(body)) : .exact(String(body))
  }

  /// Splits on everything the index's own tokenizer splits on.
  ///
  /// `unicode61` breaks on anything that is not a letter or a digit, so punctuation a client
  /// sent inside its term would never appear in a token and searching for it can only fail.
  /// Splitting the same way here means the query asks for tokens the index could actually
  /// hold.
  static func tokenize(_ text: String) -> [String] {
    text.split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { !$0.isEmpty }
  }
}
