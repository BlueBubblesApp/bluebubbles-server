//  ErrorTypePolicyTests
//  Every error type the server and the app declare can say what went wrong in a sentence.
//
//  `DiagnosticText.sentence(for:)` is the one rule for what an error says to a person, and
//  its last resort is `String(describing:)`: on a plain enum that is the CASE, so a value
//  that reaches an alert, a screen, the CLI, an audit record or a client's `error.message`
//  reads `notFinite(nan)` or `transport("Error Domain=…")`. A type that conforms to
//  `BBError` (or, where it cannot, `LocalizedError`) has written the sentence down, and
//  `BBError` adds the stable `code` and `domain` the logs and the alert centre key on.
//
//  Whether a given error ever reaches a person is a property of every `catch` above it,
//  which changes without anyone revisiting the type; so the rule is the type's, not the
//  call site's. Scanned rather than reviewed, in the shape of `SharedUtilityPolicyTests`.
//
//  Out of scope: `Helper/`, whose contract links nothing but Foundation and is translated at
//  the socket (`PrivateAPIError` is a `LocalizedError`), and the two developer tools below,
//  whose errors are printed to the terminal of whoever is generating the spec or running
//  the parity harness.

import BBTestSupport
import Foundation
import Testing

@Suite("Error types carry a sentence")
struct ErrorTypePolicyTests {

  /// Module directories under `Sources/` that only a developer runs.
  private static let developerTools: Set<String> = ["BBOpenAPI", "BBParity"]

  /// Plain error types that are allowed, by name, with the reason.
  private static let allowed: [String: String] = [
    "UnpublishedVersion":
      "private control flow in `ReleaseResolver`: thrown only by a lookup that names a "
      + "version, and that lookup's one caller catches it"
  ]

  /// Every Swift file under `Sources/` outside the developer tools, with comments removed,
  /// keyed by its repository path.
  private func corpus() throws -> [String: String] {
    var files: [String: String] = [:]
    for file in try SourceScanner.swiftFiles(under: "Sources", minimum: 101) {
      // `Sources/<module>/…`: the second component names the module.
      let module = file.path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
      guard !Self.developerTools.contains(module) else { continue }
      files[file.path] = file.code
    }
    return files
  }

  /// A declaration and its conformance clause, which may run over several lines.
  private static let declaration = try! NSRegularExpression(
    pattern: #"^[ \t]*(?:[a-z]+[ \t]+)*(?:struct|enum|class|actor)[ \t]+(\w+)[^:{\n]*:([^{]*)\{"#,
    options: [.anchorsMatchLines])

  private static let errorWord = try! NSRegularExpression(
    pattern: #"(?<![\w.])(?:Swift\.)?Error\b"#)

  private static func conformsLater(_ name: String, in text: String) -> Bool {
    let pattern =
      #"extension[ \t]+(?:\w+\.)*"# + name
      + #"[ \t]*:[^{]*\b(?:BBError|LocalizedError)\b"#
    return text.range(of: pattern, options: .regularExpression) != nil
  }

  /// Every type declared as a plain `Error`, as (path, name).
  private func plainErrorTypes() throws -> [(path: String, name: String)] {
    let files = try corpus()
    let everything = files.values.joined(separator: "\n")
    var found: [(String, String)] = []
    for (path, text) in files.sorted(by: { $0.key < $1.key }) {
      let range = NSRange(text.startIndex..., in: text)
      for match in Self.declaration.matches(in: text, range: range) {
        guard let nameRange = Range(match.range(at: 1), in: text),
          let clauseRange = Range(match.range(at: 2), in: text)
        else { continue }
        let name = String(text[nameRange])
        let clause = String(text[clauseRange])
        let clauseNS = NSRange(clause.startIndex..., in: clause)
        guard Self.errorWord.firstMatch(in: clause, range: clauseNS) != nil else { continue }
        if clause.contains("BBError") || clause.contains("LocalizedError") { continue }
        if Self.conformsLater(name, in: everything) { continue }
        found.append((path, name))
      }
    }
    return found
  }

  @Test("Every error type conforms to BBError or LocalizedError")
  func everyErrorHasASentence() throws {
    // The scan's own floor counts the developer tools too; this one counts what is checked.
    let files = try corpus()
    #expect(files.count > 100, "found only \(files.count) Swift files under Sources/")

    let offences = try plainErrorTypes().filter { Self.allowed[$0.name] == nil }
    #expect(
      offences.isEmpty,
      """
      Conform each to `BBError` (a stable `code`, a `domain`, a `title` and a `body` written \
      for a non-developer) so `DiagnosticText.sentence(for:)` renders a sentence rather than \
      the enum case:
      \(offences.map { "\($0.path): \($0.name)" }.joined(separator: "\n"))
      """)
  }

  /// The scanner is only as good as its pattern, so it is shown one of each shape.
  @Test("The scanner recognises a plain error and the ways out of the rule")
  func scannerRecognisesTheShapes() {
    let plain = "public enum Failure: Error, Equatable {\n  case a\n}"
    let split = "public enum Failure:\n  Error,\n  Equatable\n{\n  case a\n}"
    let named = "struct Thing: HTTPError {}"
    let qualified = "struct Thing: Swift.Error {}"
    func matches(_ text: String) -> Bool {
      let range = NSRange(text.startIndex..., in: text)
      return Self.declaration.matches(in: text, range: range).contains { match in
        guard let clause = Range(match.range(at: 2), in: text) else { return false }
        let body = String(text[clause])
        return Self.errorWord.firstMatch(in: body, range: NSRange(body.startIndex..., in: body))
          != nil
      }
    }
    #expect(matches(plain))
    #expect(matches(split))
    #expect(!matches(named), "a protocol whose name ends in Error is not `Error`")
    #expect(matches(qualified))
    #expect(Self.conformsLater("Failure", in: "extension Outer.Failure: BBError {"))
    #expect(!Self.conformsLater("Failure", in: "extension Outer.FailureKind: BBError {"))
  }

  /// An exception that no longer matches anything is a stale reason.
  @Test("Every exception is still needed")
  func exceptionsAreLive() throws {
    let names = Set(try plainErrorTypes().map(\.name))
    for name in Self.allowed.keys {
      #expect(names.contains(name), "\(name) is allowed but is no longer a plain error")
    }
  }
}
