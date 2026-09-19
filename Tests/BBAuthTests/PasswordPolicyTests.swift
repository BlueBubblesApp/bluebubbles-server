//  PasswordPolicyTests
//
//  The rule that matters most is negative: the policy must never run on the authentication
//  path. An existing weak password has to keep working, because every client in the field is
//  using one. Validation happens on write and nowhere else.

import Foundation
import Testing

@testable import BBAuth

@Suite("Password policy")
struct PasswordPolicyTests {

  @Test("Short passwords are rejected on change")
  func rejectsShort() {
    #expect(throws: PasswordPolicy.Rejection.tooShort(minimum: 8)) {
      try PasswordPolicy().validate("abc123")
    }
  }

  @Test("Common passwords are rejected regardless of length")
  func rejectsCommon() {
    #expect(throws: PasswordPolicy.Rejection.forbidden) {
      try PasswordPolicy().validate("bluebubbles")
    }
  }

  @Test("Repetition does not buy entropy")
  func rejectsRepetition() {
    // "aaaaaaaaaaaaaaaa" is 16 characters of one symbol. A naive length * log2(alphabet)
    // estimate would pass it.
    #expect(throws: (any Error).self) {
      try PasswordPolicy().validate("aaaaaaaaaaaaaaaa")
    }
  }

  @Test("A reasonable password is accepted")
  func acceptsReasonable() throws {
    try PasswordPolicy().validate("Tr0ub4dor&3xyz")
    try PasswordPolicy().validate("correct-horse-battery-staple")
  }

  @Test("Generated passwords satisfy the policy")
  func generatedPasswordsPass() throws {
    // Setup offers one of these, so a generated password failing the policy would be an
    // immediately visible contradiction.
    for _ in 0..<200 {
      try PasswordPolicy().validate(PasswordPolicy.generate())
    }
  }

  @Test("Generated passwords exclude ambiguous glyphs")
  func generatedPasswordsAreTranscribable() {
    // These get read off a screen and typed into a phone. A password nobody can
    // transcribe gets replaced with a weak one, which is a worse outcome than slightly
    // less entropy.
    let ambiguous = Set("0O1lI")
    for _ in 0..<200 {
      let password = PasswordPolicy.generate()
      #expect(!password.contains { ambiguous.contains($0) })
    }
  }

  @Test("Generated passwords are not obviously biased")
  func generatedPasswordsAreUniform() {
    // A weak check, but it catches the `byte % alphabet.count` mistake: with a 57-symbol
    // alphabet and a 256-value byte, the first 28 symbols would appear ~1.5x as often.
    var counts: [Character: Int] = [:]
    for _ in 0..<2_000 {
      for character in PasswordPolicy.generate(length: 20) {
        counts[character, default: 0] += 1
      }
    }
    let values = counts.values.sorted()
    let low = Double(values.first ?? 0)
    let high = Double(values.last ?? 0)
    #expect(low > 0)
    #expect(high / max(low, 1) < 1.4, "Symbol distribution looks biased: \(low)...\(high)")
  }

  @Test("Entropy rises with variety")
  func entropyOrdering() {
    let simple = PasswordPolicy.entropyBits(of: "abcdefgh")
    let mixed = PasswordPolicy.entropyBits(of: "aB3!efgh")
    #expect(mixed > simple)
  }
}
