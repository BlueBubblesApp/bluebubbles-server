//  PasswordDigest
//  The server password as a keyed digest, so the plaintext does not have to be held.
//
//  What this replaces: `passwordProvider` returned a `SecureString` read from the Keychain on
//  EVERY authenticated request, and `constantTimeEquals` walked its bytes. Two costs, one
//  obvious and one not:
//
//    1. A `SecItemCopyMatching` per request, for a value that changes approximately never.
//    2. A login keychain that locks — on sleep, or on the inactivity timeout Keychain Access
//       lets a user set — stops the server authenticating ANYONE until it is unlocked again,
//       even though the password was read successfully hours earlier.
//
//  Hashing once at first use fixes both, and is strictly better for the plaintext than what
//  it replaces: today the password is materialised into memory on every request, whereas
//  here it exists once, briefly, and never again for the life of the process.
//
//  Keyed with a per-process random key rather than a bare SHA-256. The honest description of
//  what that buys: a digest recovered on its own — from swap, a partial core file, a stale
//  page — cannot be attacked offline with a dictionary, which a bare hash of a weak password
//  very much can. It is NOT protection against an attacker who can read the whole address
//  space, because the key is in that address space too. It costs three lines, so it is worth
//  having for the first case even though it does nothing for the second.

import BBSettings
import Crypto
import Foundation

public struct PasswordDigest: Sendable, Equatable {

  /// Generated once per process. Never persisted: a digest is meaningless across restarts,
  /// which is correct — it is a cache of something authoritative in the Keychain, not a
  /// stored credential.
  private static let key = SymmetricKey(size: .bits256)

  private let digest: [UInt8]

  /// Whether the SOURCE was empty, carried alongside because the digest of "" is a
  /// perfectly ordinary digest and the auth path has to reject an unconfigured password
  /// rather than compare against it.
  public let isEmpty: Bool

  public init(_ secret: SecureString) {
    isEmpty = secret.isEmpty
    digest = secret.withUnsafeBytes { bytes in
      Array(HMAC<SHA256>.authenticationCode(for: Data(bytes), using: Self.key))
    }
  }

  public init(_ password: String) {
    self.init(SecureString(password))
  }

  /// Constant-time comparison against a candidate password.
  ///
  /// Digests are fixed-width, so a timing leak here could only reveal the prefix of a HASH,
  /// which tells an attacker nothing about the password. Kept constant-time regardless: it
  /// is free, and the property the original `constantTimeEquals` established should not
  /// quietly lapse because the thing being compared changed shape.
  public func constantTimeEquals(_ candidate: String) -> Bool {
    let candidateDigest = PasswordDigest(candidate).digest
    var difference: UInt8 = digest.count == candidateDigest.count ? 0 : 1
    for index in 0..<min(digest.count, candidateDigest.count) {
      difference |= digest[index] ^ candidateDigest[index]
    }
    return difference == 0
  }
}

/// Holds the digest for the life of the process, and gives it up when the password changes.
///
/// Only SUCCESSFUL reads are cached. That is the load-bearing rule: caching a `nil` from an
/// unreadable Keychain would make a transient failure permanent — the server would go on
/// refusing every client long after the Keychain came back — whereas leaving the cache empty
/// means the next request simply tries again. The self-healing the per-request read gave us
/// for free has to be kept deliberately once there is a cache.
public actor PasswordDigestCache {

  private let load: @Sendable () async -> SecureString?
  private var cached: PasswordDigest?

  public init(load: @escaping @Sendable () async -> SecureString?) {
    self.load = load
  }

  /// `nil` means the password could not be read, which the auth path reports as a server
  /// misconfiguration rather than a bad credential.
  public func digest() async -> PasswordDigest? {
    if let cached { return cached }
    guard let secret = await load() else { return nil }
    let digest = PasswordDigest(secret)
    cached = digest
    return digest
  }

  /// Called when `password` is written.
  ///
  /// The composition root builds the auth chain as a closure specifically so a handshake is
  /// checked against the password as it is NOW; a cache that outlived a password change
  /// would undo that and leave a rotated-away password working until the next restart,
  /// which is the opposite of what changing it means.
  public func invalidate() {
    cached = nil
  }
}
