//  FailureTranslationCoverageTests
//  The exhaustive walks are exhaustive because this says so, not because they happen to be.
//
//  `ChatFailureTests` opens by claiming it walks ALL chat operations rather than sampling,
//  and that the value is in the coverage being total. It was a literal array, complete by
//  coincidence, and its own comment admitted as much: "a new chat operation added without a
//  line here is the gap this cannot close." That is precisely the shape CLAUDE.md says ships
//  with a source scanner — a rule the compiler cannot check.
//
//  It mattered. The companion `SendFailureTests` made no exhaustiveness claim at all and
//  spot-checked four of thirteen message operations, so nine could have been missed with
//  nothing failing. Writing this scan is what found them, and they are covered now.
//
//  **The predicate is `throughMessages`**, and it is the right one because it IS the
//  translation: `MessagesBackedInterface.throughMessages` is the wrapper that turns a backend
//  refusal into `InterfaceError.messagesFailed`. So "reaches Messages and must translate" and
//  "calls `throughMessages`" are the same set by construction, rather than a heuristic that
//  drifts. `requirePrivateAPI` was the other candidate and is wrong: `create` reaches Messages
//  without it.
//
//  Operations are keyed by TYPE and name, never name alone. The first version of this file
//  keyed on the bare name and so reported `FaceTimeInterface.leave` as covered, because
//  `ChatInterface.leave` is — one collision out of fifty-nine, silently granting a pass to
//  the exact kind of operation this exists to find. Each walk declares the type it exercises
//  and its table is read within that scope.
//
//  The assertion is EXACT, in both directions. A new operation with no test fails here. So
//  does covering an exempt one without deleting its line, which is what stops the exemption
//  list below from quietly becoming permanent.

import Foundation
import Testing

@Suite("Failure translation coverage")
struct FailureTranslationCoverageTests {

  /// The suites that carry an operations table, and the interface each one exercises.
  ///
  /// The type matters: a table entry says `"leave"`, and which `leave` that is depends
  /// entirely on which suite the line is in.
  private static let walks = [
    (file: "ChatFailureTests.swift", type: "ChatInterface"),
    // `PollInterface` and `AppMessageInterface` are extensions on `MessageInterface`, so
    // their operations are in this scope too.
    (file: "SendFailureTests.swift", type: "MessageInterface"),
    (file: "FaceTimeFailureTests.swift", type: "FaceTimeInterface"),
    (file: "HandleFailureTests.swift", type: "HandleInterface"),
    (file: "AttachmentFailureTests.swift", type: "AttachmentInterface"),
    (file: "FindMyFailureTests.swift", type: "FindMyInterface"),
    // Polls and app messages are extensions on `MessageInterface`, so their tables are in
    // that scope too.
    (file: "PollFailureTests.swift", type: "MessageInterface"),
    (file: "AppMessageFailureTests.swift", type: "MessageInterface"),
  ]

  /// Operations that reach Messages and have no failure-translation test yet.
  ///
  /// Any entry is a promise that the gap is known, not that it is acceptable — and its
  /// reason must name a specific obstacle, because a vague one is how a list like this
  /// becomes permanent.
  ///
  /// Empty, and that is the point.
  ///
  /// It started at twenty-three, and every entry came off for a different reason than the
  /// one written beside it: two harnesses that already existed, a file the scan had never
  /// been pointed at, a gate whose first attempt is always allowed, a version that only
  /// needed injecting, and a fixture row nobody had written. Not one entry was retired by
  /// the effort its note estimated.
  ///
  /// Kept rather than deleted because the shape is still needed: the three assertions below
  /// are what make an addition here cost a sentence and a reason rather than nothing, and
  /// what make it fail the moment the gap is actually closed.
  private static let knownUncovered: Set<String> = []

  @Test("Every operation that reaches Messages is walked, or declared as not walked")
  func coverageIsExact() throws {
    let reaching = try Self.operationsReachingMessages()
    let walked = try Self.operationsUnderTest()

    // The floor. Without it a scan that stopped matching — a rename, a moved directory, a
    // regex typo — is indistinguishable from a tree with nothing to find, and passes.
    #expect(reaching.count > 40, "the scan found too few operations to mean anything")
    #expect(walked.count > 30, "the scan found too few tested operations to mean anything")

    let missing = reaching.subtracting(walked).subtracting(Self.knownUncovered)
    #expect(
      missing.isEmpty,
      Comment(
        rawValue: "operations reaching Messages with no failure-translation test:\n"
          + missing.sorted().joined(separator: "\n")))
  }

  @Test("An operation that IS walked is not also listed as uncovered")
  func exemptionsAreRetired() throws {
    // The direction that keeps the list above shrinking. Without it, covering an exempt
    // operation leaves its line behind, and the next reader takes a stale list as the
    // current state of the world.
    let stale = Self.knownUncovered.intersection(try Self.operationsUnderTest())
    #expect(
      stale.isEmpty,
      Comment(
        rawValue: "these are tested now and must be removed from `knownUncovered`:\n"
          + stale.sorted().joined(separator: "\n")))
  }

  @Test("Every failure-translation suite is registered as a walk")
  func everyWalkIsRegistered() throws {
    // The hole this closes cost three false entries in `knownUncovered`. `HandleInterface`
    // and `AttachmentInterface` were fully tested in a file this scan had simply never been
    // pointed at, so their operations were reported as uncovered while passing — the reading
    // that is wrong in both directions at once.
    //
    // A walk that exists and is not listed is invisible to every assertion in this file, so
    // the listing itself has to be checked against the directory rather than against memory.
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let onDisk = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .map(\.lastPathComponent)
    .filter { $0.hasSuffix("FailureTests.swift") }

    let unregistered = Set(onDisk).subtracting(Self.walks.map(\.file))
    #expect(
      unregistered.isEmpty,
      Comment(
        rawValue: "failure-translation suites missing from `walks`:\n"
          + unregistered.sorted().joined(separator: "\n")))
  }

  @Test("Every exemption names a real operation")
  func exemptionsAreReal() throws {
    // And the direction that keeps it from collecting names that no longer exist: a deleted
    // or renamed operation must not leave a permanent excuse behind.
    let phantom = Self.knownUncovered.subtracting(try Self.operationsReachingMessages())
    #expect(
      phantom.isEmpty,
      Comment(
        rawValue: "`knownUncovered` names operations that do not reach Messages:\n"
          + phantom.sorted().joined(separator: "\n")))
  }

  // MARK: - The scans

  private static var interfacesDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/BBInterfaces")
  }

  /// Public functions in `BBInterfaces` whose body calls `throughMessages`, as
  /// `Type.name`.
  ///
  /// The owning type is tracked by the nearest preceding `extension` / `actor` / `struct`
  /// declaration at column zero, because the file name does not give it: `ChatInterface`'s
  /// operations live in `ChatInterface+Administration.swift`, and `MessageInterface` gains
  /// three more from `PollInterface.swift`, which is an extension on it.
  ///
  /// Function bodies are bounded by the NEXT declaration rather than by counting braces: a
  /// brace counter has to understand string literals, comments and closures to be right, and
  /// the first draft of this scan reported `markSpam` as not reaching Messages because of one.
  private static func operationsReachingMessages() throws -> Set<String> {
    var found: Set<String> = []
    let files = try FileManager.default.contentsOfDirectory(
      at: interfacesDirectory, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }

    for file in files {
      let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
      var owner: String?
      for (index, line) in lines.enumerated() {
        if let declared = Self.declaredType(in: line) { owner = declared }
        guard let owner, let name = Self.declaredOperation(in: line) else { continue }

        let rest = lines[(index + 1)...]
        let body = rest.prefix { Self.declaredOperation(in: $0) == nil }
        if body.joined(separator: "\n").contains("throughMessages") {
          found.insert("\(owner).\(name)")
        }
      }
    }
    return found
  }

  /// `extension X`, `public actor X`, `struct X` — at column zero, so a nested type inside a
  /// function body is not mistaken for the file's own.
  private static func declaredType(in line: String) -> String? {
    let pattern =
      /^(?:public |internal |private )?(?:extension|actor|struct|final class|class|enum) ([A-Za-z_][A-Za-z0-9_]*)/
    return (try? pattern.firstMatch(in: line)).flatMap { $0.map { String($0.1) } }
  }

  /// `  public func name` at one level of indentation: a member, not a nested local function.
  private static func declaredOperation(in line: String) -> String? {
    let pattern = /^  public func ([A-Za-z_][A-Za-z0-9_]*)/
    return (try? pattern.firstMatch(in: line)).flatMap { $0.map { String($0.1) } }
  }

  /// The names in the suites' operations tables, qualified by the type each suite exercises:
  /// `("name", { … })`, in either the inline or the wrapped form the formatter produces.
  private static func operationsUnderTest() throws -> Set<String> {
    var found: Set<String> = []
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for walk in walks {
      let source = try String(
        contentsOf: directory.appendingPathComponent(walk.file), encoding: .utf8)
      // A quoted identifier, optionally with an argument suffix that distinguishes two
      // entries for one function (`setTyping(true)`), then a comma and a closure.
      let pattern = /"([A-Za-z_][A-Za-z0-9_]*)(?:\([^)"]*\))?"\s*,\s*\{/
      for match in source.matches(of: pattern) { found.insert("\(walk.type).\(match.1)") }
    }
    return found
  }
}
