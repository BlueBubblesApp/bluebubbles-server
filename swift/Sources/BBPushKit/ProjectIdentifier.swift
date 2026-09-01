//  ProjectIdentifier
//  Generating project IDs that cannot be enumerated.
//
//  Vulnerability #3: auto-provisioning creates `bluebubbles-[4 hex]` — 65,536 possibilities.
//  A remote attacker enumerates the space, finds live projects, reads each `serverUrl`, and
//  then has a list of servers to brute-force passwords against off-path. 65,536 is not a
//  search space; it is a lookup table.
//
//  Two things were wrong, and both are fixed here:
//
//    1. **Length.** Four hex characters is 16 bits. Google allows 30 characters for a project
//       ID, so the suffix now runs to the full length the prefix leaves room for.
//    2. **Source.** The current generator draws from `Math.random()`, which is not a CSPRNG —
//       predictable output makes the length irrelevant, because an attacker who can predict
//       the generator does not need to search at all.
//
//  Existing installs keep their IDs: GCP project IDs cannot be renamed, and per the decision
//  no re-provisioning flow is offered. Rule auto-remediation is what protects them.
//
//  See `.claude/docs/decisions.md`.

import Foundation

public enum ProjectIdentifier {

  /// Google's limit on a project ID.
  public static let maximumLength = 30
  /// Google's minimum.
  public static let minimumLength = 6

  /// Project IDs must be lowercase letters, digits and hyphens, and must start with a
  /// letter. Ambiguous characters are excluded so an ID read aloud or copied from a
  /// screenshot does not turn into a different one.
  static let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")

  /// A project ID with a cryptographically random suffix at full length.
  ///
  /// - Parameter prefix: Kept for recognisability in the Google Cloud console. It costs
  ///   entropy, which is why the suffix takes every character the limit leaves.
  public static func generate(prefix: String = "bluebubbles") -> String {
    let normalized =
      prefix
      .lowercased()
      .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    let stem = normalized.isEmpty ? "bluebubbles" : normalized

    // Leave room for the separating hyphen.
    let suffixLength = max(minimumLength, maximumLength - stem.count - 1)
    return "\(stem)-\(randomString(length: suffixLength))"
  }

  /// A random string from the alphabet, drawn from the system CSPRNG.
  ///
  /// `SystemRandomNumberGenerator` is documented as cryptographically secure on Apple
  /// platforms; the modulo is unbiased because the alphabet's size is a power of two.
  public static func randomString(length: Int) -> String {
    precondition(alphabet.count == 32, "the alphabet must stay a power of two to avoid modulo bias")
    var generator = SystemRandomNumberGenerator()
    return String(
      (0..<length).map { _ in
        alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))]
      })
  }

  /// Bits of entropy in an identifier produced by `generate`.
  ///
  /// Exposed so the setup UI and the tests can state the improvement rather than assert it:
  /// the old scheme was 16 bits.
  public static func entropyBits(forPrefix prefix: String = "bluebubbles") -> Int {
    let stem = prefix.isEmpty ? "bluebubbles" : prefix
    let suffixLength = max(minimumLength, maximumLength - stem.count - 1)
    // 32 symbols = 5 bits each.
    return suffixLength * 5
  }

  /// Whether an ID came from the old, enumerable scheme.
  ///
  /// Used only to explain the situation to existing users — their ID cannot be changed, and
  /// the write-deny is what actually protects them.
  public static func isLowEntropyLegacy(_ identifier: String) -> Bool {
    guard let separator = identifier.lastIndex(of: "-") else { return false }
    let suffix = identifier[identifier.index(after: separator)...]
    return suffix.count <= 5 && suffix.allSatisfy(\.isHexDigit)
  }
}
