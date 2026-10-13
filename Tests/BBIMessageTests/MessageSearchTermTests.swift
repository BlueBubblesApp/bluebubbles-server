//  MessageSearchTermTests
//  The translation from a client's `LIKE` term to an FTS5 MATCH expression.
//
//  Two reasons this is tested directly rather than only through a query. The divergences from
//  `LIKE` are DECISIONS — prefix yes, infix no, ends-with refused, multiple words ANDed — and a
//  decision that lives only in an integration test is one nobody can find later. And the term
//  is untrusted input being spliced into a query language with operators, so the quoting is a
//  correctness property in its own right.

import Testing

@testable import BBIMessage

@Suite("Message search term")
struct MessageSearchTermTests {

  private func match(_ term: String) -> String? {
    if case .match(let expression) = MessageSearchTerm.from(likeTerm: term) { return expression }
    return nil
  }

  private func reason(_ term: String) -> MessageSearchTerm.Reason? {
    if case .notExpressible(let reason) = MessageSearchTerm.from(likeTerm: term) { return reason }
    return nil
  }

  // MARK: The shapes clients send

  @Test("`%word%` becomes a prefix match")
  func containsBecomesPrefix() {
    #expect(match("%dinner%") == "\"dinner\"*")
  }

  @Test("`word%` is the same prefix match")
  func startsWithBecomesPrefix() {
    #expect(match("dinner%") == "\"dinner\"*")
  }

  @Test("A bare word with no wildcards is an exact token")
  func bareWordIsExact() {
    #expect(match("dinner") == "\"dinner\"")
  }

  @Test("Several words are ANDed, with the prefix on the last")
  func multipleWordsAreAnded() {
    // Not a phrase: `detail='none'` stores no positions, so adjacency cannot be expressed.
    // The prefix belongs on the last token only — `%see you%` is "see" and a word starting
    // with "you", which is what `LIKE` would have meant.
    #expect(match("%see you%") == "\"see\" AND \"you\"*")
  }

  // MARK: What is refused, and why each refusal is not a narrowing

  @Test("`%word` is refused: an index cannot answer `ends with`")
  func endsWithIsRefused() {
    #expect(reason("%dinner") == .endsWith)
  }

  @Test("A wildcard in the middle is refused")
  func interiorWildcardIsRefused() {
    #expect(reason("%din%ner%") == .interiorWildcard)
  }

  @Test("`_` is refused: it is a LIKE wildcard with no equivalent")
  func underscoreIsRefused() {
    // Treating it as a literal underscore would answer a different question silently.
    #expect(reason("%din_er%") == .singleCharacterWildcard)
  }

  @Test("A term with no searchable tokens is refused")
  func punctuationOnlyIsRefused() {
    #expect(reason("%...%") == .noSearchableTokens)
    #expect(reason("%%") == .noSearchableTokens)
    #expect(reason("") == .noSearchableTokens)
  }

  // MARK: Untrusted input

  @Test("FTS5 operators in a term are matched as words, not read as syntax")
  func operatorsAreQuoted() {
    // Each of these is a real FTS5 operator. Unquoted they would change the query's meaning
    // or make it a syntax error; quoted they are words to look for, which is what the user
    // typed them as.
    #expect(match("%AND%") == "\"AND\"*")
    #expect(match("%NOT%") == "\"NOT\"*")
    #expect(match("%NEAR%") == "\"NEAR\"*")
    // Punctuation the tokenizer would split on is split on here too, so the expression only
    // ever asks for tokens the index could hold.
    #expect(match("%a-b%") == "\"a\" AND \"b\"*")
    #expect(match("%(a)%") == "\"a\"*")
  }

  @Test("A double quote in a term cannot end the quoted string")
  func embeddedQuotesAreEscaped() {
    // The injection case. FTS5 escapes a quote by doubling it; without this the rest of the
    // term would be read as operators.
    //
    // The tokenizer splits on the quote itself, so what reaches the expression is two
    // ordinary tokens — which is the belt to the escaping's braces.
    #expect(match("%say \"hi\"%") == "\"say\" AND \"hi\"*")
  }

  @Test("Accents survive translation, because the tokenizer folds them")
  func accentsArePassedThrough() {
    // `remove_diacritics 2` folds on BOTH sides, so the term is passed as written and the
    // index does the folding. Stripping accents here as well would be a second, divergent
    // implementation of the same rule.
    #expect(match("%café%") == "\"café\"*")
  }

  // MARK: Anchoring

  @Test("Only a term anchored at the start is re-checked, and it says how")
  func anchoringFollowsTheWildcards() {
    #expect(MessageSearchTerm.anchoring(ofLikeTerm: "%dinner%") == nil)
    #expect(MessageSearchTerm.anchoring(ofLikeTerm: "%dinner") == nil)
    #expect(MessageSearchTerm.anchoring(ofLikeTerm: "dinner%") == .prefix("dinner"))
    #expect(MessageSearchTerm.anchoring(ofLikeTerm: "dinner%%") == .prefix("dinner"))
    #expect(MessageSearchTerm.anchoring(ofLikeTerm: "dinner") == .exact("dinner"))
  }

  @Test("A prefix admits text that starts with it, and nothing that merely contains it")
  func prefixAdmitsTheStart() {
    let prefix = MessageSearchTerm.Anchoring.prefix("see you")
    #expect(prefix.admits("see you at eight"))
    #expect(prefix.admits("see you"))
    #expect(!prefix.admits("I will see you at eight"))
    #expect(!prefix.admits("see, you"))
  }

  @Test("Exact admits the whole text and nothing longer")
  func exactAdmitsOnlyItself() {
    let exact = MessageSearchTerm.Anchoring.exact("dinner")
    #expect(exact.admits("dinner"))
    #expect(!exact.admits("dinner tonight"))
    #expect(!exact.admits("after dinner"))
  }

  @Test("Case is ignored for ASCII letters only, as LIKE ignores it")
  func asciiCaseOnly() {
    #expect(MessageSearchTerm.Anchoring.exact("DINNER").admits("dinner"))
    #expect(MessageSearchTerm.Anchoring.prefix("Din").admits("dINNER"))
    // SQLite's LIKE folds ASCII alone; a wider fold would admit what the column match
    // beside it refuses.
    #expect(!MessageSearchTerm.Anchoring.exact("\u{C9}t\u{E9}").admits("\u{E9}t\u{E9}"))
  }
}
