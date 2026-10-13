//  DocumentationStyleTests
//  The rules in `docs/WRITING.md` that a scan can check, checked on every build.
//
//  `docs/WRITING.md` states rules a compiler cannot see, which is the shape this repository
//  already answers with a source scan: a rule read once is a rule that decays, and a test that
//  greps for it runs on every build. Three groups are checkable without judgement, and they are
//  the ones here. Voice, structure and emphasis are not: a scan cannot tell a run-in heading
//  from shouting, and a scanner that guessed would be switched off within a week.
//
//  WHAT EACH GROUP COSTS. A time-anchored word dates a document to the moment it was written,
//  so a reader cannot tell a fact from a snapshot, and nothing reveals the staleness until
//  somebody acts on one. A Latin abbreviation is a skim and translation hazard for no gain:
//  `so`, `that is` and `for example` are never less clear. A non-inclusive term has a precise,
//  established replacement, and this codebase already uses the replacements in the
//  access-control code and its settings.
//
//  BOTH CORPORA ARE SCANNED: the markdown, and the comments in every Swift file. Source
//  headers and `///` comments are this project's primary documentation -- `CLAUDE.md` says so,
//  and most files open with ten to twenty-five lines of it -- so a rule that stopped at the
//  markdown would leave the larger half unchecked.
//
//  Code itself is exempt, deliberately: a fenced block is a transcript or a command, an inline
//  span is a name, and a line of Swift is not prose. `sqlite_master` is SQLite's, not ours, and
//  `NAMING.md` already says what is not ours to rename. All three are stripped or skipped
//  before a line is read.
//
//  `docs/WRITING.md` itself is exempt, because it names the terms it bans.

import BBTestSupport
import Foundation
import Testing

@Suite("Documentation follows docs/WRITING.md")
struct DocumentationStyleTests {

  /// Words that anchor a document to the moment it was written.
  static let timeAnchored = [
    "currently", "presently", "at present", "at this time", "as of this writing", "does not yet",
  ]

  /// Write `for example`, `that is`, or `and so on`, or rewrite the sentence.
  static let latinAbbreviations = ["e.g.", "i.e."]

  /// Each has an established replacement; see `docs/WRITING.md`.
  static let nonInclusive = ["sanity check", "blacklist", "whitelist"]

  // MARK: - Reading the tree

  /// Every document the guide governs: the router, the reference pages, the subsystem pages,
  /// the per-module guides and the skills.
  ///
  /// Read from named directories rather than by walking the whole tree, so the corpus is the
  /// same on every machine.
  static func documents() throws -> [(path: String, text: String)] {
    let markdown = try SourceScanner.files(under: ["docs", ".claude/docs"], extensions: ["md"])
    let skills = try SourceScanner.files(under: [".claude/skills"], extensions: ["md"])
      .filter { $0.name == "SKILL.md" }
    let guides = try SourceScanner.files(under: ["Sources", "Helper"], extensions: ["md"])
      .filter { $0.name == "CLAUDE.md" }
    let router = try SourceScanner.file("CLAUDE.md")
    return (markdown + skills + guides + [router])
      .filter { $0.path != "docs/WRITING.md" }
      .sorted { $0.path < $1.path }
      .map { ($0.path, $0.text) }
  }

  /// Every Swift file whose comments the guide governs.
  ///
  /// The scanner skips hidden directories, so the `.build` the tool packages under `Tools/`
  /// carry is never read: a checked-out dependency's comments are not ours to hold to this.
  static func sources() throws -> [SourceFile] {
    try SourceScanner.swiftFiles(
      under: "Sources", "Helper", "Tests", "Tools", "Packaging", minimum: 400)
  }

  /// The comment lines of a Swift file, with inline code spans cut.
  ///
  /// Only lines that are nothing but comment, which the scanner's lexer decides: a `//` or
  /// `///` line, or a line inside a `/* … */` block. A trailing comment after code is a margin
  /// note rather than documentation, so it is deliberately not read.
  static func comments(of file: SourceFile) -> [(number: Int, text: String)] {
    file.lines.filter(\.isComment).map { ($0.number, withoutCodeSpans($0.comment)) }
  }

  /// The comment lines of Swift written inline, for the tests that pin what counts.
  static func comments(of text: String) -> [(number: Int, text: String)] {
    comments(of: SourceFile(path: "inline.swift", url: Repository.url("inline.swift"), text: text))
  }

  /// A line with everything between backticks removed, the backticks included.
  static func withoutCodeSpans(_ line: String) -> String {
    var stripped = ""
    var inSpan = false
    for character in line {
      if character == "`" {
        inSpan.toggle()
      } else if !inSpan {
        stripped.append(character)
      }
    }
    return stripped
  }

  /// The lines of a document with code removed: fenced blocks dropped whole, inline spans cut.
  static func prose(of text: String) -> [(number: Int, text: String)] {
    var lines: [(Int, String)] = []
    var inFence = false
    for (offset, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
    {
      let line = String(raw)
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        inFence.toggle()
        continue
      }
      guard !inFence else { continue }
      lines.append((offset + 1, withoutCodeSpans(line)))
    }
    return lines
  }

  /// Whether `term` appears in `line` as a whole word, ignoring case.
  ///
  /// A letter on either side disqualifies a match, which is what keeps `concurrently` from
  /// reporting `currently`.
  static func occurs(_ term: String, in line: String) -> Bool {
    guard !line.isEmpty else { return false }
    var from = line.startIndex
    while let found = line.range(
      of: term, options: [.caseInsensitive], range: from..<line.endIndex)
    {
      let beforeIsLetter =
        found.lowerBound > line.startIndex
        && line[line.index(before: found.lowerBound)].isLetter
      let afterIsLetter = found.upperBound < line.endIndex && line[found.upperBound].isLetter
      if !beforeIsLetter && !afterIsLetter { return true }
      guard found.lowerBound < line.index(before: line.endIndex) else { return false }
      from = line.index(after: found.lowerBound)
    }
    return false
  }

  /// Every `file:line` where one of `terms` appears in prose or in a comment.
  static func offenders(for terms: [String]) throws -> [String] {
    var report: [String] = []
    func check(_ path: String, _ lines: [(number: Int, text: String)]) {
      for line in lines {
        for term in terms where occurs(term, in: line.text) {
          report.append("\(path):\(line.number)  \(term)")
        }
      }
    }
    for document in try documents() { check(document.path, prose(of: document.text)) }
    for source in try sources() { check(source.path, comments(of: source)) }
    return report
  }

  // MARK: - The scanner reads what it claims to read

  @Test("The corpus is the documentation tree")
  func corpusIsRead() throws {
    let documents = try Self.documents()
    // A scan that finds nothing passes while looking exactly like full coverage, so the floor
    // is asserted before any rule is.
    #expect(
      documents.count >= 30,
      Comment(rawValue: "only \(documents.count) documents were found; the scan is not reading"))
    #expect(documents.contains { $0.path == "CLAUDE.md" })
    #expect(documents.contains { $0.path.hasPrefix(".claude/skills/") })
    #expect(!documents.contains { $0.path == "docs/WRITING.md" }, "the guide is exempt")

    let sources = try Self.sources()
    #expect(
      sources.count >= 400,
      Comment(rawValue: "only \(sources.count) Swift files were found; the scan is not reading"))
    #expect(sources.contains { $0.path.hasPrefix("Helper/") })
    #expect(!sources.contains { $0.path.contains(".build/") }, "build directories are not ours")
  }

  @Test("The matcher finds every term it is given")
  func matcherFindsTerms() {
    for term in Self.timeAnchored + Self.latinAbbreviations + Self.nonInclusive {
      #expect(
        Self.occurs(term, in: "A sentence with \(term) in the middle of it."),
        Comment(rawValue: "the matcher does not find \(term)"))
    }
    #expect(Self.occurs("currently", in: "Currently, the value is read once."))
    #expect(!Self.occurs("currently", in: "Requests are issued sequentially, not concurrently."))
  }

  @Test("Code is not prose")
  func codeIsExempt() {
    let sample = """
      A line naming `sqlite_master` and nothing else.

      ```bash
      grep -n "currently" docs/*.md   # e.g. a transcript
      ```

      Another line.
      """
    let text = Self.prose(of: sample).map(\.text).joined(separator: "\n")
    #expect(!Self.occurs("currently", in: text))
    #expect(!Self.occurs("e.g.", in: text))
    #expect(text.contains("Another line"), "stripping must not eat the document")

    let swift = [
      "//  A header naming `sqlite_master`.",
      "let message = \"currently unavailable\"  // e.g. a margin note beside code",
      "/// What is at a URL.",
      "/* A block comment is",
      "   documentation too. */",
    ].joined(separator: "\n")
    let comments = Self.comments(of: swift).map(\.text).joined(separator: "\n")
    #expect(!Self.occurs("currently", in: comments), "a line of Swift is not a comment")
    #expect(!Self.occurs("e.g.", in: comments), "a trailing margin note is not documentation")
    #expect(comments.contains("What is at a URL"))
    #expect(comments.contains("documentation too"), "a block comment's lines are read")
  }

  // MARK: - The rules

  @Test("No time-anchored words")
  func noTimeAnchoredWords() throws {
    let found = try Self.offenders(for: Self.timeAnchored)
    #expect(
      found.isEmpty,
      Comment(
        rawValue: "a document is dated to when it was written; see docs/WRITING.md:\n"
          + found.joined(separator: "\n")))
  }

  @Test("No Latin abbreviations")
  func noLatinAbbreviations() throws {
    let found = try Self.offenders(for: Self.latinAbbreviations)
    #expect(
      found.isEmpty,
      Comment(
        rawValue: "write `for example`, `that is` or `and so on`:\n"
          + found.joined(separator: "\n")))
  }

  @Test("No non-inclusive terms")
  func noNonInclusiveTerms() throws {
    let found = try Self.offenders(for: Self.nonInclusive)
    #expect(
      found.isEmpty,
      Comment(
        rawValue: "each of these has an established replacement; see docs/WRITING.md:\n"
          + found.joined(separator: "\n")))
  }
}
