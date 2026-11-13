//  ConstantTime
//  Comparing a secret without saying where it differs.
//
//  A plain `==` returns at the first differing byte, so how long it takes says how much of
//  a guess was right, one byte at a time. Every credential comparison in the server (the
//  password digest, a `SecureString`, an enrolment code, a client-secret hash, the OAuth
//  loopback nonce) goes through this one function, because there were four copies with
//  two different answers to the length question and a fifth would have picked either.
//
//  **One length policy: a length mismatch is folded into the result, and the walk covers
//  the longer input.** Nothing returns early. The alternative, returning false as soon as
//  the lengths differ, is equally sound when both sides are fixed-width by construction,
//  and every caller but one is: an HMAC digest and an scrypt output are 32 bytes, an
//  enrolment code and the OAuth nonce have one generated length. The exception is
//  `SecureString`, which holds the server password itself, so its policy is the one kept.
//  For the fixed-width callers the two policies give the same answer in the same time.
//
//  What this still reveals, stated so nobody reads more into it: the time taken grows with
//  the LONGER of the two inputs, so a candidate shorter than the secret is walked to the
//  secret's length. That bounds the secret's length, and no more, which is the property
//  the password comparison has always had.

import Foundation

public enum ConstantTime {

  /// Whether two byte sequences are equal, without returning early.
  public static func equals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    var difference: UInt8 = lhs.count == rhs.count ? 0 : 1
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      difference |= left ^ right
    }
    return difference == 0
  }

  public static func equals(_ lhs: Data, _ rhs: Data) -> Bool {
    equals(Array(lhs), Array(rhs))
  }

  /// Compares the UTF-8 bytes, so two strings that are canonically equivalent but
  /// differently encoded are DIFFERENT here, which is right for a credential.
  public static func equals(_ lhs: String, _ rhs: String) -> Bool {
    equals(Array(lhs.utf8), Array(rhs.utf8))
  }
}
