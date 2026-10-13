//  SQLPlaceholderPolicyTests
//  A bound-parameter list is built by `SQLPlaceholders`, never by hand.
//
//  The list and the arguments bound beside it have to agree, and SQLite reports a mismatch
//  at run time on whichever route reached it. A hand-built list is where the two drift, so
//  the source tree is scanned in the shape of `SettingKeyLiteralTests` and
//  `ChatGUIDClausePolicyTests`, and a hand-built one fails the build with a file and a line.
//
//  The two shapes looked for are the two idioms a list is written in: `Array(repeating: "?"…`
//  (or a row like `"(?, ?)"`) and `.map { _ in "?" }`. The producer itself is the one file
//  allowed to spell them.

import BBCore
import BBTestSupport
import Foundation
import Testing

@Suite("SQL placeholder lists have one producer")
struct SQLPlaceholderPolicyTests {

  /// `repeating: "?"`, `repeating: "(?, ?)"`, `in "?"`: a placeholder written as the element
  /// of a repetition or a map.
  private static func handBuilt() throws -> Regex<AnyRegexOutput> {
    try Regex(#"(repeating:\s*"\(?\?|\bin\s+"\(?\?)"#)
  }

  /// The producer, and this file, which has to spell the shapes to look for them.
  private static let exempt: Set<String> = [
    "Sources/BBCore/SQLPlaceholders.swift",
    "Tests/BBCoreTests/SQLPlaceholderPolicyTests.swift",
  ]

  @Test("No source builds a placeholder list by hand")
  func oneProducer() throws {
    let handBuilt = try Self.handBuilt()
    let files = try SourceScanner.swiftFiles(under: "Sources", "Tests", "Helper", minimum: 101)
      .filter { !Self.exempt.contains($0.path) }
    let offences = SourceScanner.offences(in: files) { _, line in line.code.contains(handBuilt) }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue:
          "a placeholder list built by hand; use SQLPlaceholders.list(_:) or .rows(_:width:):\n"
          + offences.report)
    )
  }

  @Test("The scan recognises both idioms, so a clean tree is not a blind one")
  func patternMatchesBothIdioms() throws {
    let handBuilt = try Self.handBuilt()
    let shapes = [
      #"let p = Array(repeating: "?", count: ids.count).joined(separator: ", ")"#,
      #"let v = Array(repeating: "(?, ?)", count: n).joined(separator: ", ")"#,
      #"let p = ids.map { _ in "?" }.joined(separator: ",")"#,
    ]
    for shape in shapes {
      #expect(shape.contains(handBuilt), "missed: \(shape)")
    }
    #expect(!#"WHERE id IN (?)"#.contains(handBuilt))
    #expect(!#"VALUES (?, ?, ?)"#.contains(handBuilt))
  }

  @Test("A list is the count of parameters, comma-separated")
  func list() {
    #expect(SQLPlaceholders.list(0) == "")
    #expect(SQLPlaceholders.list(1) == "?")
    #expect(SQLPlaceholders.list(3) == "?, ?, ?")
  }

  @Test("Rows are parenthesised lists of the given width")
  func rows() {
    #expect(SQLPlaceholders.rows(0, width: 4) == "")
    #expect(SQLPlaceholders.rows(2, width: 1) == "(?), (?)")
    #expect(SQLPlaceholders.rows(2, width: 3) == "(?, ?, ?), (?, ?, ?)")
  }
}
