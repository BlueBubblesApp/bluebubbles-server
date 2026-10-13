//  TokenVerifier
//  Ed25519 over a compact, JWS-shaped token. Pure, synchronous, and total.
//
//  `base64url(header).base64url(claims).base64url(signature)`, signed over the first two
//  segments joined by the dot, exactly as JWS does. Not a JWT library: nothing here reads
//  `alg` from the header, because a verifier that lets the token choose its own algorithm is
//  how `alg: none` happened. The algorithm is Ed25519 because this file says so.
//
//  The same shape `AppcastSigning` already verifies release artifacts with
//  (`Sources/BBUpdates/AppcastSigning.swift`). The base64url and the raw-key parsing are
//  BBCore's (`Base64URL`, `Ed25519Keys`), which hand back bytes so that BBCore never links
//  `Crypto`; constructing the key from them is the one line that stays here.
//
//  FAILS CLOSED, ALWAYS. Every error path returns nil or throws; there is no branch that
//  treats a malformed token as permissive. That includes the unconfigured build: with no
//  public key compiled in, nothing verifies and nothing is entitled.

import BBCore
import Crypto
import Foundation

public enum TokenVerificationError: BBError, Equatable {
  /// No public key in this build. See `LicensePublicKey`.
  case notConfigured
  case malformedToken(String)
  case badSignature
  case malformedClaims(String)
  /// A token from a newer claim format than this build understands.
  case unsupportedVersion(Int)

  public var code: String {
    switch self {
    case .notConfigured: "license.token_not_configured"
    case .malformedToken: "license.token_malformed"
    case .badSignature: "license.token_bad_signature"
    case .malformedClaims: "license.token_malformed_claims"
    case .unsupportedVersion: "license.token_unsupported_version"
    }
  }

  public var domain: String { "Subscription" }
  public var title: String { "The subscription could not be verified" }

  public var body: String {
    switch self {
    case .notConfigured:
      "This build cannot verify a subscription: it has no license public key."
    case .malformedToken(let detail):
      "The license token is not in the expected form: \(detail)"
    case .badSignature:
      "The license token's signature does not match the BlueBubbles license service's key."
    case .malformedClaims(let detail):
      "The license token's contents could not be read: \(detail)"
    case .unsupportedVersion(let version):
      "The license token was written by a newer version of BlueBubbles (format \(version)). "
        + "Update to use it."
    }
  }
}

/// The signing service's public key, as base64.
///
/// The private half never exists on any machine that runs this server; it lives only in the
/// issuing function. Replacing this constant is how the key is rotated, which means rotation
/// requires a release — acceptable, because the alternative is fetching the trust anchor over
/// the network, and a trust anchor you can be talked out of is not one.
public enum LicensePublicKey {

  /// Empty until a keypair is generated and the issuing service exists.
  ///
  /// Empty is the SAFE value and the build is fully functional with it: `TokenVerifier`
  /// answers `notConfigured`, every license evaluates to `.none`, and every ungated route —
  /// which is all of them until one declares a tier — is untouched. A placeholder that
  /// verified anything would be the dangerous choice, so there is not one.
  public static let base64 = "HzGEqany62//wdr3EGCtCBlpy7TgDu1yFIMsKGUJ8H0="

  /// Whether this build can verify anything at all.
  ///
  /// The switch that decides whether the subscription gate is composed. A build with no trust
  /// anchor cannot evaluate a license, so it must not refuse anyone for failing to have one:
  /// enforcement would mean gated routes answering 402 to every caller, with no possible way
  /// to satisfy them. Unconfigured therefore gates NOTHING, and dropping a key in is what
  /// turns enforcement on.
  public static var isConfigured: Bool {
    !base64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Parses a raw 32-byte key from base64.
  ///
  /// Raw bytes, not DER: swift-crypto wants the 32 bytes and WebCrypto wants PKCS8, so the
  /// two sides agree on the only representation neither has to unwrap. Public so the
  /// cross-language fixture test can point the verifier at a throwaway key.
  public static func parse(base64: String) throws -> Curve25519.Signing.PublicKey {
    let data: Data
    do {
      data = try Ed25519Keys.rawBytes(fromBase64: base64)
    } catch Ed25519Keys.ParseError.empty {
      throw TokenVerificationError.notConfigured
    } catch {
      throw TokenVerificationError.malformedToken("public key is not 32 base64-encoded bytes")
    }
    do {
      return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    } catch {
      throw TokenVerificationError.malformedToken("public key rejected: \(error)")
    }
  }

  static func key() throws -> Curve25519.Signing.PublicKey { try parse(base64: base64) }
}

public enum TokenVerifier {

  /// The newest claim format this build can read.
  public static let supportedVersion = 1

  /// Verifies a compact token and decodes its claims.
  ///
  /// Signature FIRST, claims second. Decoding attacker-controlled JSON before establishing
  /// that we signed it would widen the attack surface to the decoder for no reason.
  public static func verify(
    _ token: String,
    publicKey: Curve25519.Signing.PublicKey? = nil
  ) throws -> EntitlementToken {
    let key = try publicKey ?? LicensePublicKey.key()

    // The split, the signature-first order and the header's `alg` are `CompactToken`'s,
    // shared with the access-token verifier. This one never read the header at all.
    let payload: Data
    do {
      payload = try CompactToken(parsing: token).verifiedClaims(
        algorithm: "EdDSA", invalidSignature: TokenVerificationError.badSignature
      ) { key.isValidSignature($0, for: $1) }
    } catch let malformed as CompactToken.Malformed {
      throw TokenVerificationError.malformedToken(malformed.reason)
    }

    let claims: EntitlementToken.Claims
    do {
      claims = try JSONDecoder().decode(EntitlementToken.Claims.self, from: payload)
    } catch {
      throw TokenVerificationError.malformedClaims(String(describing: error))
    }
    guard claims.v <= supportedVersion else {
      throw TokenVerificationError.unsupportedVersion(claims.v)
    }
    return EntitlementToken(claims: claims)
  }
}
