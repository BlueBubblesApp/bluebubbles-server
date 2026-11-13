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

import BBTestCore
import Foundation
import Testing

@Suite("CLAUDE.md does not drift from the repository")
struct DocumentationDriftTests {

  private static func guide() throws -> String {
    try Repository.read("CLAUDE.md")
  }

  /// The route table's definitions, and how many of them need the Private API.
  ///
  /// `.init(` is the route definition and nothing else in that file: a group is spelled
  /// `RouteGroup(`. Counting the opener rather than the method covers both layouts the
  /// formatter produces, since a long definition puts its method on the following line.
  private static func routeFigure() throws -> (gated: Int, total: Int) {
    let lines = try SourceScanner.file("Sources/BBHTTPAPI/RouteTable.swift").codeLines
    return (
      lines.filter { $0.code.contains("requires: .privateAPI") }.count,
      lines.filter { $0.code.contains(".init(") }.count
    )
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
      let file = Repository.url(String(path))
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
    // The floor is a scan-is-reading check, not a claim about which documents exist: a regex
    // that stops matching passes while looking exactly like full coverage. Move it with the
    // table. Ten rows since the last per-release compatibility page was folded into the
    // matrix; no release has one now.
    #expect(checked >= 10, "the size table was not found; this test checked almost nothing")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "CLAUDE.md's reference table has drifted:\n" + offenders.joined(separator: "\n"))
    )
  }

  @Test("The Private API route figure matches the route table")
  func privateAPIRouteCount() throws {
    let (gated, total) = try Self.routeFigure()
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

  /// The scanners are listed once, as a table in `docs/TESTING.md`; `CLAUDE.md` states the
  /// rule and says how many there are, in words. Both halves are held here: every name in the
  /// table is a file under `Tests/`, every `*PolicyTests.swift` that reads the tree is in the
  /// table, and the count the router gives is the table's length.
  @Test("The scanner table in docs/TESTING.md is complete, and CLAUDE.md's count is its length")
  func scannerTableIsComplete() throws {
    let testing = try Repository.read("docs/TESTING.md")
    let heading = try #require(
      testing.range(of: "| Scanner | Fails the build on |"),
      "docs/TESTING.md no longer carries the scanner table")
    let after = testing[heading.lowerBound...]
    let end = after.range(of: "\n\n")?.lowerBound ?? after.endIndex
    let table = String(after[..<end])
    let listed = try table.matches(of: Regex(#"\| `([A-Za-z]+Tests)` \|"#))
      .compactMap { $0[1].substring.map(String.init) }
    let unique = Set(listed)
    #expect(unique.count == listed.count, "a scanner is listed twice")
    #expect(unique.count >= 40, Comment(rawValue: "only \(unique.count) scanners are listed"))

    let present = Set(
      try SourceScanner.swiftFiles(under: "Tests").map { String($0.name.dropLast(".swift".count)) })
    let missing = unique.subtracting(present).sorted()
    #expect(
      missing.isEmpty,
      Comment(
        rawValue: "docs/TESTING.md lists scanners that do not exist: "
          + missing.joined(separator: ", ")))

    // The other direction: a policy test that reads the tree and is not in the table is a
    // rule nobody will find. A `*PolicyTests.swift` that never names `SourceScanner` tests a
    // policy TYPE (`PasswordPolicy`, `RetryPolicy`) and is not a scanner.
    let scanners = try SourceScanner.swiftFiles(under: "Tests")
      .filter { $0.name.hasSuffix("PolicyTests.swift") && $0.code.contains("SourceScanner.") }
      .map { String($0.name.dropLast(".swift".count)) }
    let unlisted = Set(scanners).subtracting(unique).sorted()
    #expect(
      unlisted.isEmpty,
      Comment(
        rawValue: "scanners missing from the table in docs/TESTING.md: "
          + unlisted.joined(separator: ", ")))

    // The router gives the count in words, so a row added without the sentence fails here.
    let guide = try Self.guide()
    #expect(
      guide.contains("A rule the compiler cannot check ships with a test that scans"),
      "CLAUDE.md no longer carries the policy-test rule")
    let words = [
      40: "Forty", 41: "Forty-one", 42: "Forty-two", 43: "Forty-three", 44: "Forty-four",
      45: "Forty-five", 46: "Forty-six", 47: "Forty-seven", 48: "Forty-eight", 49: "Forty-nine",
      50: "Fifty", 51: "Fifty-one", 52: "Fifty-two", 53: "Fifty-three", 54: "Fifty-four",
      55: "Fifty-five", 56: "Fifty-six", 57: "Fifty-seven", 58: "Fifty-eight", 59: "Fifty-nine",
      60: "Sixty",
    ]
    let word = try #require(
      words[unique.count], Comment(rawValue: "no word for \(unique.count) scanners; extend the map")
    )
    #expect(
      guide.contains("**\(word)** exist"),
      Comment(
        rawValue: "CLAUDE.md should say **\(word)** exist; the table has \(unique.count) rows"))
  }

  /// `docs/WRITING.md` gives each kind of document a length, because a router that has grown
  /// is skimmed and a skimmed rule is a missed one. The ceilings are pinned here so a
  /// paragraph added to the wrong tier fails the build rather than quietly costing every
  /// reader on every task. `decisions.md` has no ceiling: its row says to append a section.
  @Test("Each agent-facing document is within the length its tier allows")
  func documentLengths() throws {
    func lines(_ path: String) throws -> Int {
      try Repository.read(path).split(separator: "\n", omittingEmptySubsequences: false).count
    }
    var offenders: [String] = []
    func hold(_ path: String, to ceiling: Int) throws {
      let count = try lines(path)
      if count > ceiling { offenders.append("\(path): \(count) lines, ceiling \(ceiling)") }
    }
    try hold("CLAUDE.md", to: 400)
    for guide in try SourceScanner.files(under: ["Sources", "Helper"], extensions: ["md"])
    where guide.name == "CLAUDE.md" {
      try hold(guide.path, to: 500)
    }
    for skill in try SourceScanner.files(under: [".claude/skills"], extensions: ["md"])
    where skill.name == "SKILL.md" {
      try hold(skill.path, to: 275)
    }
    for page in try SourceScanner.files(under: [".claude/docs"], extensions: ["md"])
    where page.name != "decisions.md" {
      try hold(page.path, to: 1100)
    }
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a document is over the length docs/WRITING.md gives its tier; move the argued "
          + "paragraphs to the next tier and leave a link:\n" + offenders.joined(separator: "\n")))
  }

  /// A router that stays short does so by linking, so a link that lands nowhere is a rule a
  /// reader never reaches. Every relative link in the agent-facing documents has to name a
  /// file that exists, and an anchor has to name a heading in it, slugged the way GitHub and
  /// most editors slug one: lower case, backticks and punctuation dropped, spaces to hyphens.
  @Test("Every relative link in the agent-facing documents resolves, anchor included")
  func markdownLinksResolve() throws {
    func slug(_ heading: String) -> String {
      var text = heading.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
      text = text.replacingOccurrences(of: "`", with: "")
      text = String(
        text.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" })
      return text.replacingOccurrences(of: " ", with: "-")
    }
    func headings(of file: SourceFile) -> Set<String> {
      var found: Set<String> = []
      var inFence = false
      for line in file.text.split(separator: "\n") {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          inFence.toggle()
          continue
        }
        if !inFence, line.hasPrefix("#") { found.insert(slug(String(line))) }
      }
      return found
    }
    let documents =
      try DocumentationStyleTests.documents().map { try SourceScanner.file($0.path) }
      + [try SourceScanner.file("docs/WRITING.md")]
    let link = try Regex(#"\]\(([^)\s#]*)(#[^)\s]+)?\)"#)
    var checked = 0
    var broken: [String] = []
    for document in documents {
      let directory = document.url.deletingLastPathComponent()
      for match in document.text.matches(of: link) {
        let target = String(match[1].substring ?? "")
        let anchor = match[2].substring.map { String($0.dropFirst()) }
        if target.hasPrefix("http") || target.hasPrefix("mailto:") { continue }
        checked += 1
        var file = document
        if !target.isEmpty {
          let url = directory.appendingPathComponent(target).standardizedFileURL
          guard FileManager.default.fileExists(atPath: url.path) else {
            broken.append("\(document.path): `\(target)` is not a file")
            continue
          }
          // Only a markdown file has headings an anchor can name.
          guard anchor != nil, url.pathExtension == "md" else { continue }
          let root = Repository.root.standardizedFileURL.path
          file = try SourceScanner.file(String(url.path.dropFirst(root.count + 1)))
        }
        if let anchor, !headings(of: file).contains(anchor) {
          broken.append("\(document.path): `\(target)#\(anchor)` names no heading")
        }
      }
    }
    #expect(
      checked >= 100, Comment(rawValue: "only \(checked) links were found; the scan is not reading")
    )
    #expect(
      broken.isEmpty,
      Comment(
        rawValue: "a link in an agent-facing document lands nowhere; fix the path or the anchor:\n"
          + broken.joined(separator: "\n")))
  }

  /// The rejected-approaches index is read before a redesign, so a row that has lost its
  /// reason, its link or its date is a row that cannot answer "was this tried?". Each row has
  /// the five cells the page's own "Add a row" section names, links to where the argument
  /// lives, and carries the date it was rejected.
  @Test("Every row of the rejected-approaches index has its reason, its link and its date")
  func rejectedApproachesAreIndexed() throws {
    let page = try Repository.read(".claude/docs/rejected.md")
    guard let start = page.range(of: "## The index") else {
      Issue.record("rejected.md has no \"## The index\" section")
      return
    }
    let date = try Regex(#"^\d{4}-\d{2}-\d{2}$"#)
    let link = try Regex(#"\[[^\]]+\]\([^)]+\)"#)
    var rows = 0
    var offenders: [String] = []
    for line in page[start.upperBound...].split(separator: "\n") where line.hasPrefix("| ") {
      if line.hasPrefix("| Approach |") { continue }
      rows += 1
      let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst()
        .dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
      let name = cells.first.map { String($0.prefix(60)) } ?? String(line.prefix(60))
      guard cells.count == 5 else {
        offenders.append("\(name): \(cells.count) cells, not 5")
        continue
      }
      if cells[0].isEmpty || cells[1].isEmpty || cells[2].isEmpty {
        offenders.append("\(name): an empty approach, reason or reopen cell (write — for none)")
      }
      if !cells[3].contains(link) { offenders.append("\(name): no link to where it is argued") }
      if (try? date.wholeMatch(in: cells[4])) == nil {
        offenders.append("\(name): `\(cells[4])` is not a YYYY-MM-DD date")
      }
    }
    #expect(rows >= 15, "only \(rows) rows were found; the index was not parsed")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "a row of .claude/docs/rejected.md is missing what the page says it carries:\n"
          + offenders.joined(separator: "\n")))
  }

  /// The skills table is the same kind of claim as the policy-test paragraph, and it fails the
  /// same way: a skill nobody lists is a skill nobody invokes, and the router says how many
  /// there are in words. Both directions matter, so both are checked.
  @Test("The skills CLAUDE.md lists are the skills on disk")
  func listedSkillsExist() throws {
    let guide = try Self.guide()
    let sentence = try #require(
      guide.range(of: "skills cover the multi-step jobs that are easy to get wrong"),
      "CLAUDE.md no longer carries the skills table")
    let after = guide[sentence.lowerBound...]
    let end = after.range(of: "\n---\n")?.lowerBound ?? after.endIndex
    let table = String(after[..<end])

    let listed = Set(
      try table.matches(of: Regex(#"\| `([a-z0-9-]+)` \|"#))
        .compactMap { $0[1].substring.map(String.init) })

    // A skill is a directory directly under `.claude/skills` holding a `SKILL.md`.
    let skills = try SourceScanner.files(under: [".claude/skills"], extensions: ["md"])
      .filter { file in
        let components = file.path.split(separator: "/")
        return components.count == 4 && file.name == "SKILL.md"
      }
    let onDisk = Set(skills.map { String($0.path.split(separator: "/")[2]) })

    #expect(!onDisk.isEmpty, "no skills were found under .claude/skills")
    #expect(
      listed == onDisk,
      Comment(
        rawValue: "CLAUDE.md lists "
          + (listed.subtracting(onDisk).sorted().joined(separator: ", ").isEmpty
            ? "nothing that is missing"
            : "skills that do not exist: "
              + listed.subtracting(onDisk).sorted().joined(separator: ", "))
          + "; on disk but unlisted: "
          + (onDisk.subtracting(listed).sorted().joined(separator: ", ").isEmpty
            ? "none" : onDisk.subtracting(listed).sorted().joined(separator: ", "))))

    // The count is written in words, so it cannot be left behind by an added row.
    let words = [2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six", 7: "Seven", 8: "Eight"]
    let word = try #require(
      words[onDisk.count], Comment(rawValue: "no word for \(onDisk.count) skills"))
    #expect(
      guide.contains("\(word) skills cover the multi-step jobs"),
      Comment(
        rawValue: "CLAUDE.md should say \(word.lowercased()) skills; there are \(onDisk.count)"))

    // AGENTS.md carries the same list for tooling that does not read CLAUDE.md, and it is
    // the one that rotted: it still advertised two skills when there were six, because
    // nothing read it. The style scanner's corpus is CLAUDE.md, docs/ and .claude/, so
    // AGENTS.md sits outside every other check in this suite.
    let agents = try Repository.read("AGENTS.md")
    let listedInAgents = Set(
      try agents.matches(of: Regex(##"- \*\*`([a-z0-9-]+)`\*\*:"##))
        .compactMap { $0[1].substring.map(String.init) })
    #expect(
      listedInAgents == onDisk,
      Comment(
        rawValue: "AGENTS.md lists skills that do not exist: "
          + (listedInAgents.subtracting(onDisk).sorted().joined(separator: ", ").isEmpty
            ? "none" : listedInAgents.subtracting(onDisk).sorted().joined(separator: ", "))
          + "; on disk but unlisted: "
          + (onDisk.subtracting(listedInAgents).sorted().joined(separator: ", ").isEmpty
            ? "none" : onDisk.subtracting(listedInAgents).sorted().joined(separator: ", "))))
    #expect(
      agents.contains("\(word) packaged workflows in `.claude/skills/`"),
      Comment(
        rawValue: "AGENTS.md should say \(word.lowercased()) packaged workflows; "
          + "there are \(onDisk.count)"))

    // A skill whose front matter disagrees with its directory is one that may not resolve.
    for skill in onDisk.sorted() {
      let text = try Repository.read(".claude/skills/\(skill)/SKILL.md")
      #expect(
        text.contains("\nname: \(skill)\n"),
        Comment(rawValue: "\(skill)/SKILL.md does not declare `name: \(skill)`"))
    }
  }

  // MARK: - The other documents that carry checkable numbers

  // The TARGET count in `.claude/docs/workflow.md` is deliberately not pinned here.
  // Counting targets faithfully means reproducing what `Tools/package-graph/check.py`
  // does, and a second, looser implementation of that in Swift would be a check that
  // disagrees with the real one — which is worse than no check. The checker already runs
  // in the gate and prints the number; the document quotes it.

  @Test("The build-loop document's fixture count is the real one")
  func workflowFixtureCount() throws {
    let workflow = try Repository.read(".claude/docs/workflow.md")
    let claim = try Regex(#"`Fixtures/http/` \((\d+) files\)"#)
    let match = try #require(
      try claim.firstMatch(in: workflow),
      ".claude/docs/workflow.md no longer states a fixture count")
    let claimed = try #require(match[1].substring.flatMap { Int($0) })

    // The corpus is recorded JSON and nothing else, so its files are its JSON files.
    let files = try SourceScanner.files(
      under: ["Fixtures/http"], extensions: ["json"], recursive: false, minimum: 101)
    #expect(
      claimed == files.count,
      ".claude/docs/workflow.md says \(claimed) fixtures; there are \(files.count)")
  }

  /// The architecture document repeats the figure `CLAUDE.md` carries, and its own drift is
  /// what this suite's header names as the rot it was written to stop. It was not reading
  /// that file.
  @Test("The architecture document's Private API route figure matches the table")
  func architectureRouteFigure() throws {
    let architecture = try Repository.read(".claude/docs/architecture.md")
    let claim = try Regex(#"(\d+) of (\d+) routes are gated"#)
    guard let match = try claim.firstMatch(in: architecture) else {
      // The sentence may be reworded; that is not a failure, and pinning its exact
      // phrasing would make every edit to the paragraph a test failure.
      return
    }
    let claimedGated = try #require(match[1].substring.flatMap { Int($0) })
    let claimedTotal = try #require(match[2].substring.flatMap { Int($0) })

    let (gated, total) = try Self.routeFigure()
    #expect(
      claimedGated == gated && claimedTotal == total,
      """
      .claude/docs/architecture.md says \(claimedGated) of \(claimedTotal); the table has       \(gated) of \(total).
      """)
  }
}
