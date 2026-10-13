//  SourcePathPolicyTests
//  A test reaches a file in the tree through `Repository`, never by climbing `#filePath`.
//
//  `URL(fileURLWithPath: #filePath)` followed by one `deletingLastPathComponent()` per
//  directory is right only for the file it is written in, and only while the tree keeps its
//  shape. Move the test, or the package, and the ladder points somewhere else without
//  failing, and its hand-written labels go on naming directories that are no longer there.
//  `Repository` (`Tests/BBTestSupport`) is the one place that knows how deep it sits, and it
//  checks the answer, so every other climb out of the source file is refused.
//
//  What is matched is a STATEMENT that starts from the source file's path and climbs it:
//  `#filePath` or `#file` themselves, a parameter whose default is one of them
//  (`testFile: StaticString = #filePath`, used as `"\(testFile)"`), or a value bound from
//  either. A statement is a line plus its `.`-led continuations and anything inside open
//  brackets, read from comment-free code. `deletingLastPathComponent()` on a runtime path (a
//  temporary file's directory, a bundle) starts from no such value and is left alone.

import BBTestSupport
import Foundation
import Testing

@Suite("Tests find the tree through Repository")
struct SourcePathPolicyTests {

  /// The longest a statement may run, in lines. A ladder never needs more; the cap keeps a
  /// bracket miscounted inside a string literal from swallowing the rest of a file.
  private static let longestStatement = 12

  /// A parameter whose default is the source file's path.
  private static var pathDefault: Regex<AnyRegexOutput> {
    pattern(#"\b([A-Za-z_][A-Za-z0-9_]*)\s*:\s*[A-Za-z]+\s*=\s*#file(Path)?\b"#)
  }

  /// A binding: `let name` / `var name`, with or without a type.
  private static var binding: Regex<AnyRegexOutput> {
    pattern(#"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b"#)
  }

  /// `#file`, and not `#fileID`, which is no path at all.
  private static var fileLiteral: Regex<AnyRegexOutput> { pattern(#"#file\b"#) }

  /// A regex whose `\b` is a boundary between an identifier character and anything else.
  /// The default follows Unicode word segmentation, which reads `tests.deleting` as one
  /// word and so finds no boundary before the `.`.
  private static func pattern(_ source: String) -> Regex<AnyRegexOutput> {
    try! Regex(source).wordBoundaryKind(.simple)
  }

  /// Every statement in `file` that climbs a path derived from `#filePath`.
  static func offences(in file: SourceFile) -> [Offence] {
    let (pathDefault, binding, fileLiteral) = (Self.pathDefault, Self.binding, Self.fileLiteral)
    let lines = file.lines
    let statements = Self.statements(of: lines)

    var seeds: Set<String> = []
    for statement in statements {
      for match in statement.code.matches(of: pathDefault) {
        if let name = match.output[1].substring { seeds.insert(String(name)) }
      }
    }

    // A use of the name, not an argument label of the same spelling.
    var uses: [String: Regex<AnyRegexOutput>] = [:]
    func startsFromSource(_ code: String) -> Bool {
      if code.contains("#filePath") || code.contains(fileLiteral) { return true }
      return seeds.contains { name in
        guard code.contains(name) else { return false }
        let use = uses[name] ?? Self.pattern(#"\b"# + name + #"\b(?!\s*:)"#)
        uses[name] = use
        return code.contains(use)
      }
    }

    // A value bound from the source path is a seed too. Repeated until nothing new is
    // found, so a binding from a binding is followed.
    var grew = true
    while grew {
      grew = false
      for statement in statements where startsFromSource(statement.code) {
        guard !statement.code.contains("deletingLastPathComponent"),
          let match = statement.code.firstMatch(of: binding),
          let name = match.output[1].substring.map(String.init),
          !seeds.contains(name)
        else { continue }
        seeds.insert(name)
        grew = true
      }
    }

    return statements.compactMap { statement in
      guard statement.code.contains("deletingLastPathComponent"),
        startsFromSource(statement.code)
      else { return nil }
      return Offence(file, lines[statement.firstLine])
    }
  }

  /// A statement's comment-free code, and the index of its first line.
  private struct Statement {
    let firstLine: Int
    let code: String
  }

  /// Splits `lines` into statements: a line, the lines after it that start with `.`, and
  /// every line while a bracket it opened is still open.
  private static func statements(of lines: [SourceLine]) -> [Statement] {
    var statements: [Statement] = []
    var index = 0
    while index < lines.count {
      let first = index
      var code = lines[index].code
      var depth = Self.depth(of: code)
      index += 1
      while index < lines.count, index - first < longestStatement {
        let next = lines[index].code
        let trimmed = next.trimmingCharacters(in: .whitespaces)
        guard depth > 0 || trimmed.hasPrefix(".") else { break }
        code += "\n" + next
        depth = max(0, depth + Self.depth(of: next))
        index += 1
      }
      statements.append(Statement(firstLine: first, code: code))
    }
    return statements
  }

  /// Opening brackets minus closing ones, outside double-quoted strings.
  private static func depth(of code: String) -> Int {
    var depth = 0
    var inString = false
    var escaped = false
    for character in code {
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        continue
      }
      switch character {
      case "\"": inString = true
      case "(", "[": depth += 1
      case ")", "]": depth -= 1
      default: break
      }
    }
    return depth
  }

  @Test("No test outside BBTestSupport climbs out of #filePath")
  func noPathLadders() throws {
    let ownName = URL(fileURLWithPath: #filePath).lastPathComponent
    let files = try SourceScanner.swiftFiles(under: "Tests", minimum: 101)
      .filter { !$0.path.hasPrefix("Tests/BBTestSupport/") && $0.name != ownName }
    let offenders = files.flatMap(Self.offences(in:))
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: """
          a test climbs out of its own source path to reach the tree. Use \
          `Repository.url("<path from the repository root>")`, `Repository.read(_:)` or \
          `Repository.root` (BBTestSupport) instead:
          \(offenders.report)
          """))
  }

  /// The matcher, against the shapes it must and must not catch, so a scan that finds
  /// nothing is known to be looking.
  @Test("The matcher finds every ladder shape and leaves a runtime path alone")
  func matcherSelfTest() {
    func lines(_ text: String) -> [Int] {
      Self.offences(
        in: SourceFile(path: "t.swift", url: Repository.url("t.swift"), text: text)
      ).map(\.line)
    }
    // The labelled ladder, one hop per line.
    #expect(
      lines(
        """
        static let corpus = URL(fileURLWithPath: #filePath)
          .deletingLastPathComponent()  // Tests
          .deletingLastPathComponent()  // swift
          .appendingPathComponent("Fixtures/http")
        """) == [1])
    // On one line, reported where it is.
    #expect(
      lines(
        "let a = 1\nlet root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()")
        == [2])
    // A `#filePath` default, interpolated into the path.
    #expect(
      lines(
        """
        func corpus(testFile: StaticString = #filePath) -> URL {
          URL(fileURLWithPath: "\\(testFile)")
            .deletingLastPathComponent()
        }
        """) == [2])
    // Bound first, climbed later, through a second binding.
    #expect(
      lines(
        """
        let here = URL(fileURLWithPath: #filePath)
        let tests = here
        let root = tests.deletingLastPathComponent()
        """) == [3])
    // The arguments wrapped inside the brackets.
    #expect(
      lines("let u = URL(\n  fileURLWithPath: #filePath\n).deletingLastPathComponent()") == [1])
    // `NSString`, `#file`, and the newer initialiser.
    #expect(lines("let d = (#filePath as NSString).deletingLastPathComponent") == [1])
    #expect(lines("let d = URL(filePath: #file).deletingLastPathComponent()") == [1])

    // A runtime path climbs nothing in the tree.
    #expect(lines("let directory = staged.deletingLastPathComponent()") == [])
    #expect(
      lines("defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }")
        == [])
    #expect(lines("let directory = (path as NSString).deletingLastPathComponent") == [])
    // `#filePath` that does not climb.
    #expect(lines("let ownName = URL(fileURLWithPath: #filePath).lastPathComponent") == [])
    // A label spelled like a seed is not a use of it.
    #expect(
      lines(
        """
        func check(file: StaticString = #filePath) {}
        let dir = report(file: path).deletingLastPathComponent()
        """) == [])
    // A comment is not code.
    #expect(lines("// URL(fileURLWithPath: #filePath).deletingLastPathComponent()") == [])
    // Statements end where the line does, unless the next one continues it.
    #expect(
      lines(
        """
        let ownName = URL(fileURLWithPath: #filePath).lastPathComponent
        let directory = staged.deletingLastPathComponent()
        """) == [])
  }
}
