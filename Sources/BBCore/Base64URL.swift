//  Base64URL
//  The JWS/JWT alphabet, and the raw Ed25519 key bytes three modules parse.
//
//  base64url is base64 with `-` and `_` for `+` and `/`, and with the padding dropped. The
//  token issuer, the licence verifier and the Google service-account assertion all speak
//  it, and each had its own encoder; two had their own decoder. They agreed, which is the
//  point of having one: the day one of them is "fixed" the others would not be.
//
//  `Ed25519Keys` is here, and not beside the keys, because BBCore must not link `Crypto`:
//  the launcher depends on BBCore alone, and every target in the package depends on it.
//  So it answers the part that was duplicated (trim, decode, check the length) and hands
//  back bytes; the one-line `Curve25519.Signing.*Key(rawRepresentation:)` stays with the
//  caller, along with what each caller calls a failure.

import Foundation

public enum Base64URL {

  /// base64url without padding, as JWS writes it.
  public static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// base64url, padding optional.
  ///
  /// JWS omits the padding and `Data(base64Encoded:)` requires it, so it is restored here
  /// rather than the token format being bent to suit Foundation. A length that no padding
  /// can complete (one more than a multiple of four) stays invalid and answers nil.
  public static func decode(_ text: String) -> Data? {
    var working = text.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = working.count % 4
    if remainder != 0 { working += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: working)
  }
}

/// Raw Ed25519 key material from its base64 form.
///
/// Raw bytes, not DER: swift-crypto wants the 32 bytes, and both the licence service and
/// Sparkle exchange exactly those.
public enum Ed25519Keys {

  /// The length of a public key and of a private key's seed.
  public static let rawLength = 32

  /// The length of a libsodium secret key: the 32-byte seed followed by the public key.
  /// This is what Sparkle's `generate_keys` exports.
  public static let libsodiumSecretKeyLength = 64

  public enum ParseError: BBError, Equatable {
    /// Nothing but whitespace.
    case empty
    case notBase64
    case wrongLength(Int)

    public var code: String {
      switch self {
      case .empty: "key.empty"
      case .notBase64: "key.not_base64"
      case .wrongLength: "key.wrong_length"
      }
    }

    public var domain: String { "Core" }
    public var title: String { "That key could not be read" }

    public var body: String {
      switch self {
      case .empty: "The key is empty."
      case .notBase64: "The key is not valid base64."
      case .wrongLength(let count):
        "The key is \(count.counted("byte")) long; an Ed25519 key is "
          + "\(Ed25519Keys.rawLength.counted("byte"))."
      }
    }
  }

  /// The 32 raw bytes of a public key, or of a private key's seed.
  ///
  /// Surrounding whitespace is ignored, since a key pasted from a terminal or read out of a
  /// file carries a newline more often than not.
  ///
  /// - Parameter acceptingLibsodiumSecretKey: Also accept the 64-byte libsodium layout and
  ///   return its seed. Only for a PRIVATE key from a tool that exports that layout; a
  ///   public key is never 64 bytes, and accepting it there would take the first half of
  ///   whatever was pasted.
  public static func rawBytes(
    fromBase64 encoded: String, acceptingLibsodiumSecretKey: Bool = false
  ) throws(ParseError) -> Data {
    let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw .empty }
    guard let data = Data(base64Encoded: trimmed) else { throw .notBase64 }
    switch data.count {
    case rawLength:
      return data
    case libsodiumSecretKeyLength where acceptingLibsodiumSecretKey:
      return data.prefix(rawLength)
    default:
      throw .wrongLength(data.count)
    }
  }
}
