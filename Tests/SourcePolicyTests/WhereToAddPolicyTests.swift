//  WhereToAddPolicyTests
//  Every row of CLAUDE.md's "Where do I add…?" table points at a place that exists, and the
//  symbols it says are there are there.
//
//  That table is the part of the router an agent acts on most directly: it is read at the
//  moment of deciding which file to open, and it is followed without reading further. A row
//  that names a file which has moved, or a symbol which has moved to a sibling file, sends
//  the reader to the wrong place with full confidence, and they then add the thing a second
//  time where the row said it goes. Splitting `SettingsRegistry.swift` into section files is
//  the shape of change that breaks a row: every name in it still exists, so the scan for
//  dangling names (`CommentReferencePolicyTests`) passes, and only the claim of WHERE is false.
//
//  THE RULE. In each row's second column:
//
//  - a span shaped like a path (it has a `/`, or a file extension) names a file or a
//    directory in the tree. A partial path (`Views/Onboarding/OnboardingSteps.swift`, a bare
//    `ValidationRules.swift`) counts when some path in the tree ends with it, because a row
//    gives the full path once and abbreviates after. `<Section>` and `*` are wildcards;
//  - when a cell opens with a path and a colon, every symbol in the clause that follows, up
//    to the next path, `then`, a `never`, a `not`, a semicolon or a sentence break, is
//    spelled in the code under that path. A negated symbol is the one a row says NOT to use;
//  - a symbol followed by a path in brackets (`` `TablePage` (`…/SettingsLayout.swift`) ``)
//    is spelled in the code under that path;
//  - a path introduced by `in` (`` add it to `Settings.renderable` in `SettingsRegistry.swift` ``)
//    places every symbol earlier in the same clause, back to a sentence break, a semicolon, a
//    colon, an `, and` or a negation.
//
//  "Spelled" is the same weak test the reference scan uses: the identifier appears in code.
//  It holds for a type a row says to declare in a file and for one a row says to add an
//  instance of there, which are both rows this table has.

import BBTestCore
import Foundation
import Testing

@Suite("CLAUDE.md's where-to-add table points at places that exist")
struct WhereToAddPolicyTests {

  static let pointsAtTheTree = PolicyRule(
    rule: "Each path in CLAUDE.md's \"Where do I add…?\" table exists, and each symbol a row "
      + "places in a file or directory is spelled there.",
    fix: "Update the row to the path where the thing lives now. If a symbol moved to a sibling "
      + "file, name that file, or the family as `Name+<Part>.swift`.",
    home: #"CLAUDE.md, "Where do I add…?""#)

  /// The extensions a path span can carry, which is what tells a path from a symbol.
  static let pathExtensions: Set<String> = ["swift", "md", "py", "sh", "ts", "m", "h", "json"]

  /// The second column of every row of the table.
  static func rows() throws -> [(label: String, cell: String)] {
    let guide = try Repository.read("CLAUDE.md")
    guard let start = guide.range(of: "## Where do I add") else { return [] }
    let section = guide[start.upperBound...].prefix { _ in true }
    var rows: [(String, String)] = []
    for line in section.split(separator: "\n") {
      if line.hasPrefix("## ") || line == "---" { break }
      guard line.hasPrefix("| "), !line.hasPrefix("| To add"), !line.hasPrefix("|---") else {
        continue
      }
      let cells = line.split(separator: "|", omittingEmptySubsequences: false)
      guard cells.count >= 4 else { continue }
      let label = cells[1].trimmingCharacters(in: .whitespaces)
      let cell = cells[2...].dropLast().joined(separator: "|").trimmingCharacters(in: .whitespaces)
      rows.append((label, cell))
    }
    return rows
  }

  /// Whether a code span is shaped like a path rather than a symbol.
  static func isPath(_ span: String) -> Bool {
    if span.contains(" ") || span.contains("(") { return false }
    if span.contains("/") { return true }
    let ext = (span as NSString).pathExtension.lowercased()
    return pathExtensions.contains(ext) && !span.dropLast(ext.count + 1).contains(".")
  }

  /// The identifiers a symbol span names: `OnboardingCatalog.steps` is two, `Setting<T>` one,
  /// `presentation:` one. Nil for a span that is not a symbol at all (`[a-z0-9]{4,32}`).
  static func identifiers(of span: String) -> [String]? {
    var text = span
    if let generic = text.firstIndex(of: "<") { text = String(text[..<generic]) }
    if let call = text.firstIndex(of: "(") { text = String(text[..<call]) }
    text = text.trimmingCharacters(in: CharacterSet(charactersIn: ":."))
    let parts = text.split(separator: ".").map(String.init)
    guard !parts.isEmpty,
      parts.allSatisfy({ part in
        part.first.map { $0.isLetter || $0 == "_" } == true
          && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
      })
    else { return nil }
    return parts
  }

  /// The code spans of `text`, with where each starts.
  static func spans(in text: String) -> [(span: String, start: String.Index, end: String.Index)] {
    var found: [(String, String.Index, String.Index)] = []
    var index = text.startIndex
    while let open = text[index...].firstIndex(of: "`") {
      let after = text.index(after: open)
      guard let close = text[after...].firstIndex(of: "`") else { break }
      found.append((String(text[after..<close]), open, text.index(after: close)))
      index = text.index(after: close)
    }
    return found
  }

  // MARK: - The tree

  struct Tree {
    var files: [SourceFile]
    var directories: Set<String>

    /// Every file or directory path that `span` names, as a partial path or a wildcard.
    func matches(_ span: String) throws -> [String] {
      let trimmed = span.hasSuffix("/") ? String(span.dropLast()) : span
      var pattern = "(^|/)"
      var inPlaceholder = false
      for character in trimmed {
        switch character {
        case "<": inPlaceholder = true
        case ">":
          inPlaceholder = false
          pattern += "[^/]+"
        case "*": pattern += "[^/]*"
        default:
          if !inPlaceholder {
            pattern += NSRegularExpression.escapedPattern(for: String(character))
          }
        }
      }
      pattern += "$"
      let regex = try Regex(pattern)
      let candidates = (span.hasSuffix("/") ? [] : files.map(\.path)) + directories
      return candidates.filter { $0.contains(regex) }
    }

    /// The code of every file at or under one of `paths`.
    func code(under paths: [String]) -> String {
      files.filter { file in
        paths.contains { file.path == $0 || file.path.hasPrefix($0 + "/") }
      }.map(\.code).joined(separator: "\n")
    }
  }

  static func tree() throws -> Tree {
    let files = try SourceScanner.files(
      under: [
        "Sources", "Helper", "Tests", "Tools", "Packaging", "docs", ".claude",
        "electron/packages/server/src",
      ],
      extensions: pathExtensions, minimum: 1000)
    var directories: Set<String> = []
    for file in files {
      var parts = file.path.split(separator: "/").dropLast()
      while !parts.isEmpty {
        directories.insert(parts.joined(separator: "/"))
        parts = parts.dropLast()
      }
    }
    let top = try SourceScanner.files(under: [""], extensions: pathExtensions, recursive: false)
    return Tree(files: files + top, directories: directories)
  }

  /// Whether `identifier` appears as a whole identifier in `code`.
  static func spells(_ code: String, _ identifier: String) -> Bool {
    var from = code.startIndex
    while let found = code.range(of: identifier, range: from..<code.endIndex) {
      let before =
        found.lowerBound > code.startIndex ? code[code.index(before: found.lowerBound)] : " "
      let after = found.upperBound < code.endIndex ? code[found.upperBound] : " "
      let boundary: (Character) -> Bool = { !($0.isLetter || $0.isNumber || $0 == "_") }
      if boundary(before) && boundary(after) { return true }
      from = found.upperBound
    }
    return false
  }

  // MARK: - The claims a row makes

  struct Placement: Equatable {
    var symbol: String
    var path: String
  }

  /// What ends the clause a placement reads: a sentence, a list item, a negation.
  static let clauseBreaks = [" then ", ";", ". ", ": ", ", and ", "**", "never", " not "]

  /// Every symbol a cell places under a path, by the three shapes the header describes.
  static func placements(in cell: String) -> [Placement] {
    let spans = spans(in: cell)
    var placed: [Placement] = []

    // A cell that opens with a path and a colon.
    if let first = spans.first, first.start == cell.startIndex, isPath(first.span),
      cell[first.end...].hasPrefix(":")
    {
      for next in spans.dropFirst() {
        // The colon that opens the clause is not one that ends it.
        let between = cell[cell.index(after: first.end)..<next.start]
        if clauseBreaks.contains(where: { between.contains($0) }) { break }
        if isPath(next.span) { break }
        if identifiers(of: next.span) != nil {
          placed.append(Placement(symbol: next.span, path: first.span))
        }
      }
    }

    // A symbol followed by a path in brackets, with a few words between at most.
    for (offset, span) in spans.enumerated() where identifiers(of: span.span) != nil {
      guard offset + 1 < spans.count else { continue }
      let next = spans[offset + 1]
      let between = cell[span.end..<next.start]
      guard isPath(next.span), between.hasSuffix("("), between.count <= 20,
        !between.contains("`"), cell[next.end...].hasPrefix(")")
      else { continue }
      placed.append(Placement(symbol: span.span, path: next.span))
    }

    // A path introduced by `in` or `in the`, which places every symbol earlier in its clause.
    for (offset, path) in spans.enumerated() where isPath(path.span) {
      let before = cell[..<path.start]
      guard before.hasSuffix(" in ") || before.hasSuffix(" in the ") else { continue }
      for earlier in spans[..<offset].reversed() {
        let between = cell[earlier.end..<path.start]
        if clauseBreaks.contains(where: { between.contains($0) }) || isPath(earlier.span) {
          break
        }
        if identifiers(of: earlier.span) != nil {
          placed.append(Placement(symbol: earlier.span, path: path.span))
        }
      }
    }
    return placed
  }

  // MARK: - The scan reads what it claims to read

  @Test("The table, its paths and its placements are found")
  func corpusIsRead() throws {
    let rows = try Self.rows()
    #expect(rows.count >= 20, "only \(rows.count) rows were found; the table was not parsed")
    let paths = rows.flatMap { Self.spans(in: $0.cell).map(\.span) }.filter(Self.isPath)
    #expect(paths.count >= 25, "only \(paths.count) paths were found in the table")
    let placements = rows.flatMap { Self.placements(in: $0.cell) }
    #expect(placements.count >= 10, "only \(placements.count) placements were found")
  }

  @Test("Paths and placements are told apart from prose")
  func classification() throws {
    #expect(Self.isPath("Sources/BBHandlers/"))
    #expect(Self.isPath("ValidationRules.swift"))
    #expect(Self.isPath("SettingsRegistry+<Section>.swift"))
    #expect(!Self.isPath("Settings.renderable"))
    #expect(!Self.isPath("throughMessages { … }"))
    #expect(Self.identifiers(of: "Setting<T>") == ["Setting"])
    #expect(Self.identifiers(of: "presentation:") == ["presentation"])
    #expect(Self.identifiers(of: "[a-z0-9]{4,32}") == nil)

    let opening = Self.placements(
      in: "`Sources/A/F.swift`: a case in `Kind`, an entry in `Catalog.steps`, then `Elsewhere`")
    #expect(opening.map(\.symbol) == ["Kind", "Catalog.steps"])
    let bracketed = Self.placements(in: "`TablePage` (`Views/Layout.swift`), never `Other`")
    #expect(bracketed == [Placement(symbol: "TablePage", path: "Views/Layout.swift")])
    let introduced = Self.placements(
      in: "`Sources/A/`: declare `Kind`, and add it to `List.all` (or `List.none`) in `List.swift`")
    #expect(
      introduced.filter { $0.path == "List.swift" }.map(\.symbol) == ["List.none", "List.all"])

    let tree = Tree(
      files: [
        SourceFile(
          path: "Sources/BBSettings/SettingsRegistry+Connection.swift",
          url: Repository.url("x.swift"), text: "")
      ],
      directories: ["Sources", "Sources/BBSettings"])
    #expect(try tree.matches("SettingsRegistry+<Section>.swift").count == 1)
    #expect(try tree.matches("Sources/BBSettings/").count == 1)
    #expect(try tree.matches("BBSettings/*.swift").count == 1)
    #expect(try tree.matches("BBSettings/SettingsRegistry.swift").isEmpty)
  }

  // MARK: - The rule

  @Test("Every path and every placement in the table resolves")
  func tablePointsAtTheTree() throws {
    let tree = try Self.tree()
    var offenders: [String] = []
    for row in try Self.rows() {
      for span in Self.spans(in: row.cell).map(\.span) where Self.isPath(span) {
        if try tree.matches(span).isEmpty {
          offenders.append("\(row.label): `\(span)` names nothing in the tree")
        }
      }
      for placement in Self.placements(in: row.cell) {
        let paths = try tree.matches(placement.path)
        guard !paths.isEmpty else { continue }
        let code = tree.code(under: paths)
        for identifier in Self.identifiers(of: placement.symbol) ?? []
        where !Self.spells(code, identifier) {
          offenders.append(
            "\(row.label): `\(placement.symbol)` is not in `\(placement.path)`"
              + " (no `\(identifier)` there)")
        }
      }
    }
    #expect(offenders.isEmpty, Self.pointsAtTheTree.comment(offenders))
  }
}
