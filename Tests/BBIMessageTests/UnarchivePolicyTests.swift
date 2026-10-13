//  UnarchivePolicyTests
//  A keyed archive is unarchived with secure coding on, except where a reason is recorded.
//
//  What a message carries is a stranger's input, and an `NSKeyedUnarchiver` with secure
//  coding off instantiates any `NSCoding` class the process has loaded, whatever class list
//  it is handed: the list binds only when `requiresSecureCoding` is true. A list beside a
//  `false` reads as a restriction and is none, which is how `AttributedBody` came to say
//  "class-restricted" above a decode that was not. `AppMessagePayload.root(of:)` is the
//  shape: secure, an allowlist, and a placeholder delegate for names the process lacks.
//
//  The deprecated one-shot APIs are refused for the same reason: they are not secure.

import BBTestSupport
import Testing

@Suite("Keyed unarchiving is secure")
struct UnarchivePolicyTests {

  /// Files allowed an insecure keyed unarchive, and why. Each needs its reason in place too.
  private static let knowinglyInsecure: [String: String] = [
    "Sources/BBIMessage/AttributedBody.swift":
      "no keyed attributedBody has been seen to check a class list against; see its comment"
  ]

  @Test("No source turns secure coding off or uses an insecure one-shot unarchive")
  func secureByDefault() throws {
    let pattern = try Regex(
      #"requiresSecureCoding\s*=\s*false|unarchiveObject\(with|unarchiveTopLevelObjectWithData"#)
    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 101)
      .filter { Self.knowinglyInsecure[$0.path] == nil }
    let offences = SourceScanner.offences(in: files) { _, line in line.code.contains(pattern) }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue:
          "an insecure keyed unarchive; follow AppMessagePayload.root(of:):\n"
          + offences.report)
    )
  }

  @Test("Every recorded exception still exists, so the list cannot outlive its reason")
  func exceptionsAreCurrent() throws {
    for path in Self.knowinglyInsecure.keys {
      let source = try SourceScanner.file(path).code
      #expect(source.contains("requiresSecureCoding = false"), "\(path) no longer needs it")
    }
  }
}
