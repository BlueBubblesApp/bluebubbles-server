//  FieldValidationTests
//  The rule a field's value must satisfy before a form will store it.
//
//  Written for zrok's reserved share name, whose rule zrok states as "must be lowercase
//  alphanumeric, between 4 and 32 characters in length, screened for profanity". Nothing
//  checked it, so an invalid name was accepted by the form and refused by zrok — and because
//  the service retries, the report was 175 identical alerts in 71 seconds behind a drawer
//  that was not open.

import Testing

@testable import BBServiceKit

@Suite("Field validation")
struct FieldValidationTests {

  /// zrok's rule, as declared on the reserved-name field.
  private let zrok = FieldValidation(
    pattern: "[a-z0-9]{4,32}",
    message: "zrok names must be 4 to 32 characters, lowercase letters and digits only."
  )

  /// THE REGRESSION. `bb-test` is what was typed, and what zrok refused 175 times.
  ///
  /// It also pins the anchoring: the pattern matches `bb` nowhere, but a rule checked with a
  /// partial match would accept `test-` on the strength of its first four characters.
  @Test("A name with a hyphen is refused, and so is anything else zrok would refuse")
  func refusesWhatZrokRefuses() {
    #expect(zrok.failure(for: "bb-test") != nil, "the name that produced 175 alerts")
    #expect(zrok.failure(for: "my-server") != nil, "the placeholder the field used to show")
    #expect(zrok.failure(for: "BBTest") != nil, "capitals")
    #expect(zrok.failure(for: "bb test") != nil, "a space")
    #expect(zrok.failure(for: "bb_test") != nil, "an underscore")
    #expect(zrok.failure(for: "abc") != nil, "under four characters")
    #expect(zrok.failure(for: String(repeating: "a", count: 33)) != nil, "over thirty-two")
    // The message is what the person reads, so it is the return value rather than a Bool.
    #expect(zrok.failure(for: "bb-test") == zrok.message)
  }

  @Test("A name zrok would accept passes")
  func acceptsValidNames() {
    for name in ["bbtest", "abcd", "server1", String(repeating: "a", count: 32), "0000"] {
      #expect(zrok.failure(for: name) == nil, "refused \(name)")
    }
  }

  /// Empty means "zrok picks one" for this field, which is not the same as invalid.
  @Test("Empty is allowed when the field says so, and refused when it does not")
  func emptyFollowsTheField() {
    #expect(zrok.failure(for: "") == nil)
    #expect(zrok.failure(for: "   ") == nil, "whitespace only is empty")

    let mandatory = FieldValidation(
      pattern: "[a-z0-9]{4,32}", message: "Required.", allowsEmpty: false)
    #expect(mandatory.failure(for: "") == mandatory.message)
  }

  /// Surrounding whitespace is the user's, not the value's: a pasted name with a trailing
  /// space is the name they meant.
  @Test("A value is judged trimmed")
  func trimsBeforeJudging() {
    #expect(zrok.failure(for: "  bbtest  ") == nil)
  }

  /// A manifest with a broken rule must not make its own field impossible to fill in. The
  /// rule goes unenforced and the service still reports what its backend says.
  @Test("A pattern that cannot compile refuses nothing")
  func aBrokenPatternIsNotAGate() {
    let broken = FieldValidation(pattern: "[unclosed", message: "nope")
    #expect(broken.failure(for: "anything at all") == nil)
  }
}
