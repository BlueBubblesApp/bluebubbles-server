//  DiagnosticTextTests
//  The one rule for "what does this error say to a person".
//
//  There were two. `DiagnosticText.sentence(for:)` in this module, and a `userFacingMessage`
//  free function in the SwiftUI app that answered the same question with two of the steps
//  spelled differently, while `ErrorRenderer.message(for:)` carried a comment saying that two
//  rules for one question would drift. The app's extra step was the half worth keeping, so it
//  moved here and the duplicate is gone.
//
//  These tests exist because the merged rule has behaviour that is easy to regress and
//  invisible when it does: every case below produces a plausible-looking string either way, and
//  the wrong one is only obviously wrong to somebody reading it in a settings screen.

import Foundation
import Testing

@testable import BBCore

@Suite("The sentence an error offers a person")
struct DiagnosticTextTests {

  /// Our own vocabulary: a `BBError` whose `body` is the sentence written for a reader.
  private struct Refusal: BBError {
    let code = "test.refusal"
    let domain = "Test"
    let title = "Refused"
    let body: String
  }

  /// A `BBError` that adopted the protocol and left the sentence blank.
  private struct Wordless: BBError {
    let code = "test.wordless"
    let domain = "Test"
    let title = "Wordless"
    let body = ""
  }

  /// Wrote an explanation without adopting `BBError`.
  private struct Explained: LocalizedError {
    var errorDescription: String? { "The tunnel refused the connection." }
  }

  /// A plain enum carrying its values in the case, which is what most of ours are.
  private enum Plain: Error {
    case tooPredictable(bits: Double, minimum: Double)
  }

  @Test("A BBError's own body wins")
  func bodyWins() {
    #expect(
      DiagnosticText.sentence(for: Refusal(body: "That password is too easy to guess."))
        == "That password is too easy to guess."
    )
  }

  @Test("A BBError with an empty body falls through instead of returning nothing")
  func emptyBodyFallsThrough() {
    // The step that must not be skipped: handing a caller "" puts an empty error view on
    // screen, which is worse than the structure: nothing at all is shown and nothing
    // says why.
    let sentence = DiagnosticText.sentence(for: Wordless())
    #expect(!sentence.isEmpty)
  }

  @Test("A LocalizedError's own description is preferred over anything inferred")
  func localizedErrorWins() {
    #expect(DiagnosticText.sentence(for: Explained()) == "The tunnel refused the connection.")
  }

  @Test("Foundation's own errors say what they mean rather than dumping their structure")
  func foundationErrorsAreReadable() throws {
    // The step the app had and this module did not. Both of these fail the `LocalizedError`
    // cast (measured, not assumed) so without it they reach `String(describing:)` and a
    // user is shown `Error Domain=NSCocoaErrorDomain Code=4 …` or three lines of decoding
    // debug description.
    #expect(DiagnosticText.sentence(for: CocoaError(.fileNoSuchFile)) == "The file doesn’t exist.")

    let decoding: any Error
    do {
      _ = try JSONDecoder().decode(Int.self, from: Data("not json".utf8))
      Issue.record("decoding the fixture should have failed")
      return
    } catch {
      decoding = error
    }
    let sentence = DiagnosticText.sentence(for: decoding)
    #expect(!sentence.contains("DecodingError"))
    #expect(!sentence.contains("Debug description"))
  }

  @Test("An NSError carrying its own description uses it")
  func nsErrorWithDescription() {
    let error = NSError(
      domain: "Zork", code: 42,
      userInfo: [NSLocalizedDescriptionKey: "Zork ran out of grues."]
    )
    #expect(DiagnosticText.sentence(for: error) == "Zork ran out of grues.")
  }

  @Test("Foundation's synthesised placeholder is rejected in favour of the value's structure")
  func synthesisedPlaceholderIsRejected() {
    // `localizedDescription` on a plain Swift enum is "The operation couldn't be completed.
    // (BBCoreTests.…Plain error 0.)", which says strictly less than the case does. The case
    // at least carries the numbers a person can act on.
    let sentence = DiagnosticText.sentence(for: Plain.tooPredictable(bits: 34.2, minimum: 60.0))
    #expect(sentence == "tooPredictable(bits: 34.2, minimum: 60.0)")
  }

  @Test("A bare NSError with no message of its own is not reported as a completed operation")
  func bareNSErrorIsRejected() {
    let sentence = DiagnosticText.sentence(for: NSError(domain: "Zork", code: 42))
    #expect(!sentence.contains("couldn’t be completed"))
  }

  @Test("The placeholder is recognised by domain and code, not by its English wording")
  func placeholderDetectionIsNotEnglishOnly() {
    // Foundation localises that sentence, so a server running in another language would
    // start showing "Die Operation konnte nicht abgeschlossen werden. (Zork error 42.)" to
    // a string matcher looking for the English. The domain and the code are interpolated in
    // every language, and they are what this matches.
    //
    // Asserted as a property rather than by switching locales, which a test process cannot
    // do reliably: whatever the wording, a description carrying `(<domain> error <code>` is
    // the placeholder and must be rejected.
    let error = NSError(
      domain: "Zork", code: 42,
      userInfo: [NSLocalizedDescriptionKey: "Die Operation konnte nicht (Zork error 42.)"]
    )
    let sentence = DiagnosticText.sentence(for: error)
    #expect(sentence != "Die Operation konnte nicht (Zork error 42.)")
  }
}
