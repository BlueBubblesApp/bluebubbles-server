//  AppcastSigning
//  Ed25519 signatures over release artifacts, in Sparkle's format.
//
//  Sparkle's own `sign_update` tool does exactly this: Ed25519 over the file's raw bytes,
//  base64-encoded, into `sparkle:edSignature`. Reimplemented against swift-crypto rather than
//  shelled out to, for two reasons — `sign_update` ships inside the Sparkle distribution and
//  would have to be present on the release runner, and having it here means the signature can
//  be VERIFIED in a test rather than trusted.
//
//  That verification matters more than it sounds. A wrong signature produces a perfectly
//  valid-looking appcast that every shipped install silently refuses, and the symptom —
//  "nobody is getting updates" — appears weeks later with nothing in any log.
//
//  See `CONTRIBUTING.md` and the residual risk on key loss in § Residual risks.

import BBCore
import Crypto
import Foundation

public enum AppcastSigning {

  public enum SigningError: BBError, Equatable, LocalizedError {
    case malformedPrivateKey(String)
    case malformedPublicKey(String)
    case unreadableFile(String)

    public var errorDescription: String? {
      switch self {
      case .malformedPrivateKey(let reason): "The Sparkle private key is unusable: \(reason)"
      case .malformedPublicKey(let reason): "The Sparkle public key is unusable: \(reason)"
      case .unreadableFile(let path): "Could not read \(path)"
      }
    }
  }

  /// Loads a private key from the base64 form Sparkle's `generate_keys` exports.
  ///
  /// That export is the libsodium layout: 64 bytes, a 32-byte seed followed by the 32-byte
  /// public key. swift-crypto wants the seed alone, so the tail is dropped. A 32-byte input
  /// is also accepted, since that is what a raw seed looks like and pasting one is an easy
  /// mistake to make with no way to tell from the error otherwise.
  public static func privateKey(fromBase64 encoded: String) throws -> Curve25519.Signing.PrivateKey
  {
    let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed) else {
      throw SigningError.malformedPrivateKey("not valid base64")
    }
    let seed: Data
    switch data.count {
    case 64: seed = data.prefix(32)
    case 32: seed = data
    default:
      throw SigningError.malformedPrivateKey(
        "expected 32 or 64 bytes, got \(data.count)"
      )
    }
    do {
      return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    } catch {
      throw SigningError.malformedPrivateKey(String(describing: error))
    }
  }

  public static func publicKey(fromBase64 encoded: String) throws -> Curve25519.Signing.PublicKey {
    let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed), data.count == 32 else {
      throw SigningError.malformedPublicKey("expected 32 base64-encoded bytes")
    }
    do {
      return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    } catch {
      throw SigningError.malformedPublicKey(String(describing: error))
    }
  }

  /// The base64 signature for an artifact's bytes.
  public static func signature(
    for data: Data,
    privateKey: Curve25519.Signing.PrivateKey
  ) throws -> String {
    try privateKey.signature(for: data).base64EncodedString()
  }

  /// Signs a file on disk.
  ///
  /// Memory-mapped rather than read: a DMG is hundreds of megabytes and the release runner
  /// does not need to hold all of it at once to hash it.
  public static func signature(
    forFileAt path: String,
    privateKey: Curve25519.Signing.PrivateKey
  ) throws -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    else { throw SigningError.unreadableFile(path) }
    return try signature(for: data, privateKey: privateKey)
  }

  /// Whether a signature verifies. Used by the tests, and by the release script's own
  /// self-check before it publishes anything.
  public static func isValid(
    signature encoded: String,
    for data: Data,
    publicKey: Curve25519.Signing.PublicKey
  ) -> Bool {
    guard let signature = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespaces))
    else { return false }
    return publicKey.isValidSignature(signature, for: data)
  }

  /// The base64 public key matching a private key, in the form that goes into the app's
  /// `SUPublicEDKey` Info.plist entry.
  public static func publicKeyBase64(
    for privateKey: Curve25519.Signing.PrivateKey
  ) -> String {
    privateKey.publicKey.rawRepresentation.base64EncodedString()
  }
}

extension AppcastSigning.SigningError {
  public var code: String {
    switch self {
    case .malformedPrivateKey: "appcast.malformed_private_key"
    case .malformedPublicKey: "appcast.malformed_public_key"
    case .unreadableFile: "appcast.unreadable_file"
    }
  }

  public var domain: String { "Updates" }

  public var isUserFacing: Bool { true }

  public var severity: Severity { .critical }

  public var title: String { "An update could not be verified" }

  public var body: String { errorDescription ?? "This failed and reported no reason." }
}
