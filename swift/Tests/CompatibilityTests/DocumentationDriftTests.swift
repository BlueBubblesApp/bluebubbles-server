//  DocumentationDriftTests
//  The numbers CLAUDE.md states about this repository are still the repository's numbers.
//
//  CLAUDE.md is the file every agent and every new contributor reads first, and it is full of
//  counts and sizes: how many routes need the Private API, how many source-scanning policy
//  tests exist, how long each reference document is. A count in prose is a claim nothing
//  checks, and all three kinds had rotted: the route claim said 60 of 148 when it was 70 of
//  166, seven policy scanners when there were fourteen, and ten of the twelve document sizes
//  were wrong, two of them by a factor of nearly three.
//
//  None of that is cosmetic. The size column exists so a reader knows whether to open a file
//  or grep it; "~10 KB" for a 28 KB document is advice that leads them to read the wrong way.
//  The route figure is the one number that says how much of this server needs the Private
//  API, which is the first thing anyone evaluating a configuration asks.
//
//  So the numbers are pinned. This is the same pattern as every other policy test here: the
//  rule is one a compiler cannot see, so a test reads the tree and fails the build. Tolerance
//  is deliberately loose, because the point is to catch a claim that has become MISLEADING,
//  not to make every commit that adds a paragraph fail.

import Foundation
import Testing

@Suite("CLAUDE.md does not drift from the repository")
struct DocumentationDriftTests {

  /// The `swift/` directory, located from this file rather than from the working directory.
  private static var root: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func guide() throws -> String {
    try String(contentsOf: root.appending(path: "CLAUDE.md"), encoding: .utf8)
  }

  @Test("Every documented document size is within a quarter of the real one")
  func referenceDocumentSizes() throws {
    let row = try Regex(#"^\| \[`([^`]+)`\]\(([^)]+)\) \| ~(\d+) KB \|"#)
    var checked = 0
    var offenders: [String] = []
    for line in try Self.guide().split(separator: "\n") {
      guard let match = try? row.firstMatch(in: String(line)) ?? nil,
        let path = match[2].substring, let claimed = match[3].substring.flatMap({ Int($0) })
      else { continue }
      let file = Self.root.appending(path: String(path))
      guard let data = try? Data(contentsOf: file) else {
        offenders.append("\(path): named in the table and not on disk")
        continue
      }
      checked += 1
      let actual = Int((Double(data.count) / 1024).rounded())
      // A quarter either way. A document that has grown by a third is one the reader was
      // told to expect something materially smaller than.
      let drift = abs(Double(actual - claimed)) / Double(max(actual, 1))
      if drift > 0.25 {
        offenders.append("\(path): the table says ~\(claimed) KB and it is \(actual) KB")
      }
    }
    #expect(checked >= 12, "the size table was not found; this test checked almost nothing")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "CLAUDE.md's reference table has drifted:\n" + offenders.joined(separator: "\n"))
    )
  }

  @Test("The Private API route figure matches the route table")
  func privateAPIRouteCount() throws {
    let source = try String(
      contentsOf: Self.root.appending(path: "Sources/BBHTTPAPI/RouteTable.swift"),
      encoding: .utf8)
    // `.init(` is the route definition and nothing else in this file: a group is spelled
    // `RouteGroup(`. Counting the opener rather than the method covers both layouts the
    // formatter produces, since a long definition puts its method on the following line.
    var total = 0
    var gated = 0
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let code = line.trimmingCharacters(in: .whitespaces)
      if code.hasPrefix("//") { continue }
      if code.contains(".init(") { total += 1 }
      if code.contains("requires: .privateAPI") { gated += 1 }
    }
    #expect(total > 100, "the route scan found too few definitions to mean anything")

    let claim = try Regex(#"(\d+) of the (\d+) route definitions"#)
    let guide = try Self.guide()
    let found = try claim.firstMatch(in: guide)
    let match = try #require(found, "CLAUDE.md no longer states the Private API route figure")
    let claimedGated = try #require(match[1].substring.flatMap { Int($0) })
    let claimedTotal = try #require(match[2].substring.flatMap { Int($0) })
    #expect(
      claimedGated == gated && claimedTotal == total,
      """
      CLAUDE.md says \(claimedGated) of \(claimedTotal) route definitions need the Private \
      API; the table now has \(gated) of \(total).
      """)
  }

  @Test("Every source-scanning policy test CLAUDE.md names still exists")
  func namedPolicyTestsExist() throws {
    let guide = try Self.guide()
    let sentence = try #require(
      guide.range(of: "A rule the compiler cannot check ships with a test that scans"),
      "CLAUDE.md no longer carries the policy-test rule")
    let paragraph = String(guide[sentence.lowerBound...].prefix(2400))

    let named = try paragraph.matches(of: Regex(#"`([A-Za-z]+Tests)`"#))
      .compactMap { $0[1].substring.map(String.init) }
    let unique = Set(named)
    #expect(
      unique.count >= 14,
      Comment(rawValue: "CLAUDE.md names \(unique.count) policy scanners; it claims fourteen"))

    var present: Set<String> = []
    if let walker = FileManager.default.enumerator(
      atPath: Self.root.appending(path: "Tests").path)
    {
      for case let relative as String in walker where relative.hasSuffix(".swift") {
        present.insert(
          (relative as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: ""))
      }
    }
    #expect(!present.isEmpty, "the test tree was not found")
    let missing = unique.subtracting(present).sorted()
    #expect(
      missing.isEmpty,
      Comment(
        rawValue: "CLAUDE.md names tests that no longer exist: " + missing.joined(separator: ", ")))
  }

  // MARK: - The other documents that carry checkable numbers

  private static func read(_ relative: String) throws -> String {
    try String(contentsOf: root.appending(path: relative), encoding: .utf8)
  }

  // The TARGET count in `.claude/docs/workflow.md` is deliberately not pinned here.
  // Counting targets faithfully means reproducing what `Tools/package-graph/check.py`
  // does, and a second, looser implementation of that in Swift would be a check that
  // disagrees with the real one — which is worse than no check. The checker already runs
  // in the gate and prints the number; the document quotes it.

  @Test("The build-loop document's fixture count is the real one")
  func workflowFixtureCount() throws {
    let workflow = try Self.read(".claude/docs/workflow.md")
    let claim = try Regex(#"`Fixtures/http/` \((\d+) files\)"#)
    let match = try #require(
      try claim.firstMatch(in: workflow),
      ".claude/docs/workflow.md no longer states a fixture count")
    let claimed = try #require(match[1].substring.flatMap { Int($0) })

    let corpus = Self.root.appending(path: "Fixtures/http")
    let files = try FileManager.default.contentsOfDirectory(atPath: corpus.path)
      .filter { !$0.hasPrefix(".") }
    #expect(files.count > 100, "the corpus scan found \(files.count) files")
    #expect(
      claimed == files.count,
      ".claude/docs/workflow.md says \(claimed) fixtures; there are \(files.count)")
  }

  /// The architecture document repeats the figure `CLAUDE.md` carries, and its own drift is
  /// what this suite's header names as the rot it was written to stop. It was not reading
  /// that file.
  @Test("The architecture document's Private API route figure matches the table")
  func architectureRouteFigure() throws {
    let architecture = try Self.read(".claude/docs/architecture.md")
    let claim = try Regex(#"(\d+) of (\d+) routes are gated"#)
    guard let match = try claim.firstMatch(in: architecture) else {
      // The sentence may be reworded; that is not a failure, and pinning its exact
      // phrasing would make every edit to the paragraph a test failure.
      return
    }
    let claimedGated = try #require(match[1].substring.flatMap { Int($0) })
    let claimedTotal = try #require(match[2].substring.flatMap { Int($0) })

    let source = try Self.read("Sources/BBHTTPAPI/RouteTable.swift")
    var total = 0
    var gated = 0
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let code = line.trimmingCharacters(in: .whitespaces)
      if code.hasPrefix("//") { continue }
      if code.contains(".init(") { total += 1 }
      if code.contains("requires: .privateAPI") { gated += 1 }
    }
    #expect(
      claimedGated == gated && claimedTotal == total,
      """
      .claude/docs/architecture.md says \(claimedGated) of \(claimedTotal); the table has       \(gated) of \(total).
      """)
  }
}
