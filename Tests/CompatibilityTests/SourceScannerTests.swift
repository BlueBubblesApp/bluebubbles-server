//  SourceScannerTests
//  The lexer every policy test reads through.
//
//  A policy test is only as good as its idea of what a comment is: call code a comment and
//  an offence hides, call a comment code and a sentence about the rule becomes a finding.
//  These pin the cases the prefix test got wrong.

import BBTestSupport
import Testing

@Suite("Source scanner")
struct SourceScannerTests {

  private func lines(_ text: String) -> [SourceLine] {
    SourceFile(path: "t.swift", url: Repository.url("t.swift"), text: text).lines
  }

  @Test("A trailing comment is comment, and the code before it is code")
  func trailingComment() {
    let line = lines("let x = 1  // never do this")[0]
    #expect(line.code == "let x = 1  ")
    #expect(line.comment == " never do this")
    #expect(!line.isComment)
  }

  @Test("Comment markers inside a string are string")
  func markersInStrings() {
    let line = lines(#"let url = "https://example.com/*path*/""#)[0]
    #expect(line.code == line.text)
    #expect(line.comment.isEmpty)
  }

  @Test("A block comment spans lines, and nests")
  func nestedBlock() {
    let result = lines("a /* one /* two */ still\nstill */ b")
    #expect(result[0].code == "a ")
    #expect(result[1].code == " b")
    #expect(result[1].comment.contains("still"))
  }

  @Test("A raw string keeps its quotes and backslashes")
  func rawString() {
    let line = lines(##"let r = #"a \" // b"# // c"##)[0]
    #expect(line.code == ##"let r = #"a \" // b"# "##)
    #expect(line.comment == " c")
  }

  @Test("A multi-line string is code on every line")
  func multilineString() {
    let result = lines("let s = \"\"\"\n// not a comment\n\"\"\" // a comment")
    #expect(result[1].code == "// not a comment")
    #expect(result[1].comment.isEmpty)
    #expect(result[2].comment == " a comment")
  }

  @Test("An escaped quote does not close the string")
  func escapedQuote() {
    let line = lines(#"let s = "say \"hi\" // still string" // comment"#)[0]
    #expect(line.comment == " comment")
  }

  @Test("Interpolation is code, and may hold its own strings")
  func interpolation() {
    let line = lines(#"let s = "a \(f("x)")) b" // done"#)[0]
    #expect(line.code == #"let s = "a \(f("x)")) b" "#)
    #expect(line.comment == " done")
  }

  @Test("Line numbers count from one and include the last line")
  func lineNumbers() {
    let result = lines("one\ntwo\nthree")
    #expect(result.map(\.number) == [1, 2, 3])
    #expect(lines("one\n").count == 1)
  }

  @Test("A scan with too few files throws rather than passing")
  func floor() {
    #expect(throws: SourceScanError.self) {
      try SourceScanner.files(under: ["Tests/BBTestSupport"], minimum: 10_000)
    }
    #expect(throws: SourceScanError.self) {
      try SourceScanner.files(under: ["no-such-directory"])
    }
  }

  @Test("Paths are relative to the repository root")
  func relativePaths() throws {
    let files = try SourceScanner.swiftFiles(under: "Tests/BBTestSupport")
    #expect(files.contains { $0.path == "Tests/BBTestSupport/SourceScanner.swift" })
  }

  @Test("A single file is read by its repository path, and a missing one throws")
  func singleFile() throws {
    let file = try SourceScanner.file("Tests/BBTestSupport/Repository.swift")
    #expect(file.path == "Tests/BBTestSupport/Repository.swift")
    #expect(file.code.contains("public enum Repository"))
    #expect(throws: (any Error).self) { try SourceScanner.file("Tests/no-such-file.swift") }
  }
}
