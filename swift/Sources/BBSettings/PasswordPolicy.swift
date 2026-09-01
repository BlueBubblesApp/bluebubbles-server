//  PasswordPolicy
//  Entropy requirements, enforced ONLY on set and change.
//
//  The constraint that shapes this file: an existing weak password must keep working. Every
//  client in the field authenticates with the password it was given, so validating on READ
//  would lock out an entire fleet the moment the server updated. The policy therefore runs
//  at exactly one point — when a password is being written — and never on the auth path.
//
//  The current default is an EMPTY password, which is what makes the off-path brute-forcing
//  in the 2023 report worth attempting at all. Setup now generates a strong one and offers
//  it, so the common case is strong by default rather than strong by diligence.
//
//  It lives in BBSettings rather than BBAuth because the write path is here — attaching it
//  to the `password` descriptor is what makes it unbypassable. In BBAuth it was public,
//  fully tested, and called by nothing: every route to setting a password went straight past
//  it, so a one-character server password was accepted without comment. BBAuth re-exports it
//  so existing `import BBAuth` call sites are unaffected.
//
//  See `.claude/docs/decisions.md`.

import BBCore
import Foundation

public struct PasswordPolicy: Sendable {

  public var minimumLength: Int
  public var minimumEntropyBits: Double
  /// Rejected outright regardless of length. Short list on purpose — a large blocklist is
  /// a false sense of security and an attacker is not guessing from our list.
  public var forbidden: Set<String>

  public init(
    minimumLength: Int = 8,
    minimumEntropyBits: Double = 40,
    forbidden: Set<String> = [
      "password", "bluebubbles", "12345678", "123456789", "qwertyui", "imessage",
    ]
  ) {
    self.minimumLength = minimumLength
    self.minimumEntropyBits = minimumEntropyBits
    self.forbidden = forbidden
  }

  /// Why a password was refused.
  ///
  /// `LocalizedError` is not decoration. The settings write path throws this straight out of
  /// the `validate` closure without wrapping it, so anything that catches generically had
  /// only `String(describing:)` to fall back on — which renders the associated values and
  /// puts `tooPredictable(bits: 34.2, minimum: 60.0)` in front of someone who wanted to
  /// know their password was too easy to guess. Conforming here means the friendly sentence
  /// survives the trip no matter who catches it.
  public enum Rejection: BBError, LocalizedError, Sendable, Equatable {
    case tooShort(minimum: Int)
    case tooPredictable(bits: Double, minimum: Double)
    case forbidden

    public var userMessage: String {
      switch self {
      case .tooShort(let minimum):
        "Too short — use at least \(minimum) characters."
      case .tooPredictable:
        // Deliberately says nothing about entropy or bits. The number is what the check
        // measures, not something the reader can act on; "add more variety" is.
        "Too easy to guess. Try a longer phrase, or mix in numbers and symbols — or use "
          + "Generate for one that is strong by construction."
      case .forbidden:
        "That is one of the most commonly used passwords. Pick something else."
      }
    }

    /// What a generic `catch` sees. The same sentence, so there is only one message.
    public var errorDescription: String? { userMessage }
  }

  /// Called from the settings write path, never from authentication.
  public func validate(_ candidate: String) throws {
    guard candidate.count >= minimumLength else {
      throw Rejection.tooShort(minimum: minimumLength)
    }
    guard !forbidden.contains(candidate.lowercased()) else {
      throw Rejection.forbidden
    }
    let bits = Self.entropyBits(of: candidate)
    guard bits >= minimumEntropyBits else {
      throw Rejection.tooPredictable(bits: bits, minimum: minimumEntropyBits)
    }
  }

  // MARK: - Advisory

  /// A non-blocking verdict on a password that is ALREADY in use.
  ///
  /// `validate` is a gate and applies only to new values. This is the other half: a server
  /// migrated from the Electron build brings its old password with it, deliberately
  /// unvalidated — locking those installs out at upgrade time would be far worse than the
  /// weak password. So the existing value is never rejected, only reported, and the UI
  /// shows the advice next to the field where it can be acted on.
  public enum Strength: Sendable, Equatable {
    case unset
    case weak(reason: String)
    case acceptable
    case strong

    public var isConcerning: Bool {
      switch self {
      case .unset, .weak: true
      case .acceptable, .strong: false
      }
    }

    /// nil when there is nothing to say, so the UI can bind straight to it.
    public var advice: String? {
      switch self {
      case .unset:
        "No server password is set. Anyone who can reach this server can read your "
          + "messages."
      case .weak(let reason):
        reason
      case .acceptable, .strong:
        nil
      }
    }
  }

  /// Assesses without throwing. Safe to call on every keystroke.
  public func assess(_ candidate: String) -> Strength {
    guard !candidate.isEmpty else { return .unset }
    do {
      try validate(candidate)
    } catch let rejection as Rejection {
      return .weak(reason: rejection.userMessage)
    } catch {
      return .weak(reason: "This password is weaker than recommended.")
    }
    // Comfortably past the floor rather than just over it.
    return Self.entropyBits(of: candidate) >= minimumEntropyBits * 2 ? .strong : .acceptable
  }

  /// A rough entropy estimate: log2(alphabet) * length, with a penalty for repetition.
  ///
  /// Deliberately not zxcvbn. A dictionary-aware estimator is better at scoring human
  /// passwords, but it is a large dependency and a moving target, and the goal here is to
  /// reject obviously-guessable values rather than to rank good ones.
  public static func entropyBits(of password: String) -> Double {
    guard !password.isEmpty else { return 0 }

    var alphabet = 0
    let scalars = password.unicodeScalars
    if scalars.contains(where: { $0 >= "a" && $0 <= "z" }) { alphabet += 26 }
    if scalars.contains(where: { $0 >= "A" && $0 <= "Z" }) { alphabet += 26 }
    if scalars.contains(where: { $0 >= "0" && $0 <= "9" }) { alphabet += 10 }
    if scalars.contains(where: { !CharacterSet.alphanumerics.contains($0) }) { alphabet += 32 }
    guard alphabet > 1 else { return 0 }

    let distinct = Double(Set(password).count)
    // "aaaaaaaaaa" is ten characters of one symbol, not ten characters of entropy.
    let repetitionFactor = min(1.0, distinct / Double(password.count) + 0.3)

    return log2(Double(alphabet)) * Double(password.count) * repetitionFactor
  }

  /// What setup offers. 20 characters from a 62-symbol alphabet is ~119 bits.
  ///
  /// Ambiguous glyphs are excluded because this gets read off a screen and typed into a
  /// phone — a password nobody can transcribe gets replaced with a weak one.
  public static func generate(length: Int = 20) -> String {
    let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    var result = ""
    result.reserveCapacity(length)

    // SystemRandomNumberGenerator is the CSPRNG here; the current server's
    // generateRandomString uses Math.random, which is not one. That matters most for
    // project IDs (report finding 3), but there is no reason to have two qualities of
    // randomness in one codebase.
    //
    // `Int.random(in:)` rather than `byte % alphabet.count`: 256 is not a multiple of
    // 57, so the modulo would make the first few symbols measurably likelier. Small
    // bias, free to avoid.
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<length {
      result.append(alphabet[Int.random(in: 0..<alphabet.count, using: &generator)])
    }
    return result
  }
}

extension PasswordPolicy.Rejection {
  public var code: String {
    switch self {
    case .tooShort: "password.too_short"
    case .tooPredictable: "password.too_predictable"
    case .forbidden: "password.forbidden"
    }
  }

  public var domain: String { "Settings" }

  public var isUserFacing: Bool { true }

  public var title: String { "That password was not accepted" }

  public var body: String { errorDescription ?? "This failed and reported no reason." }
}
