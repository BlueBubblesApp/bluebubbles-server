//  SourceSizePolicyTests
//  A Swift source file stays under a thousand lines.
//
//  Agents and people read source in slices, and a file of one to two thousand lines loses
//  its shape in the process: the header is out of view by the time the reader reaches the
//  declaration it explains, and a seam the file already has (a MARK, a nested type, an
//  extension) is invisible from inside it. The seam is where a file is split, as a pure
//  move into a sibling named for the part (`RequestBodies+Messages.swift`,
//  `ChangeDetector+State.swift`), and `SourceScanner.family(_:)` lets a policy about the
//  type keep reading all of it.
//
//  The ceiling is a count of lines, which is the measure a reader meets. The allowlist
//  names the files over it with the reason each stays whole, so a file that grows past the
//  ceiling fails the build until it is split or its reason is written down, and a reason
//  that has stopped being true is reported the build after the file is split.

import BBTestCore
import Testing

@Suite("Source files stay under the size ceiling")
struct SourceSizePolicyTests {

  /// Lines, as an editor counts them. A file at the ceiling is not over it.
  static let ceiling = 1000

  static let underCeiling = PolicyRule(
    rule: "A Swift file under `Sources/` or `Helper/` is at most \(ceiling) lines.",
    fix: "Split it along a seam it already has, as a pure move into a sibling file named for "
      + "the part, and name the siblings in the base file's header; or add it to "
      + "`SourceSizePolicyTests.allowed` with a one-sentence reason.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  /// Files over the ceiling, each with the reason it stays whole. A file that is split
  /// leaves this list in the same change.
  static let allowed: [String: String] = [:]

  private static func sizes() throws -> [(path: String, lines: Int)] {
    try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 500)
      .map { ($0.path, $0.lines.count) }
  }

  @Test("No file under Sources or Helper exceeds the ceiling")
  func filesStayUnderCeiling() throws {
    let offenders = try Self.sizes()
      .filter { $0.lines > Self.ceiling && Self.allowed[$0.path] == nil }
      .map { "\($0.path): \($0.lines) lines" }
    #expect(offenders.isEmpty, Self.underCeiling.comment(offenders))
  }

  @Test("Every allowed file is still over the ceiling, so the list carries no stale entry")
  func allowlistIsCurrent() throws {
    let byPath = Dictionary(uniqueKeysWithValues: try Self.sizes().map { ($0.path, $0.lines) })
    let stale = Self.allowed.keys.filter { (byPath[$0] ?? 0) <= Self.ceiling }.sorted()
    #expect(stale.isEmpty, "allowed and no longer over the ceiling; remove: \(stale)")
  }
}
