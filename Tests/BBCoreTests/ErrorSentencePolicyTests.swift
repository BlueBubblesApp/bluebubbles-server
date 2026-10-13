//  ErrorSentencePolicyTests
//  What an error says to a person comes from `DiagnosticText.sentence(for:)`, not from a
//  property read beside it.
//
//  `localizedDescription` is step three of that function, and read on its own it is the step
//  that fails: on one of our enums it is Foundation's placeholder, "The operation couldn't be
//  completed. (BBPrivateAPI.PrivateAPIError error 2.)", which says less than the value. The
//  function knows when to skip it. Every hand-written read was a fourth copy of a rule that
//  has one home.

import BBTestSupport
import Foundation
import Testing

@Suite("Error sentences")
struct ErrorSentencePolicyTests {

  private static let allowed: [String: String] = [
    "Sources/BBCore/BBError.swift": "`DiagnosticText` itself",
    "Sources/BlueBubblesLauncher/main.swift": "an `NSLog` line, which is a log and not a sentence",
    "Sources/BBTooling/ReleaseResolver.swift":
      "the reason inside a typed error, which renders it through its own `body`",
  ]

  @Test("No localizedDescription read outside DiagnosticText")
  func sentencesGoThroughTheDoor() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", minimum: 100)
      .filter { Self.allowed[$0.path] == nil }
    let offences = SourceScanner.offences(in: files) { _, line in
      line.code.contains(".localizedDescription")
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "these read `localizedDescription` by hand; use "
          + "`DiagnosticText.sentence(for:)`:\n" + offences.report))
  }
}
