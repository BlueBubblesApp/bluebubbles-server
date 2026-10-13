//  CompactToken
//  A compact JWS (`header.claims.signature`), split and checked in one place.
//
//  Two verifiers read this form: the access tokens this server issues (`BBAuth`) and the
//  entitlement tokens the license service issues (`BBLicense`). Each parsed it by hand and they
//  disagreed on what a token is: one checked the header's `alg` and the other never read the
//  header at all, and they split on "." with different rules for an empty segment. The day a
//  second algorithm is accepted anywhere, an unchecked header is how `alg: none` gets in.
//
//  The signature itself stays with each caller, which holds its own key and its own crypto
//  dependency; this type fixes the ORDER. The signature is checked before any JSON is read,
//  the header included, so nothing an attacker wrote is decoded until the token is known to
//  be signed.

import Foundation

public struct CompactToken: Sendable {

  /// What the signature covers: the first two segments as they arrived.
  public let signingInput: Data
  public let signature: Data
  private let header: Data
  private let claims: Data

  /// Why a token is not one, in a sentence for a log or a typed error's reason.
  public struct Malformed: BBError, Equatable {
    public let reason: String
    public var code: String { "token.malformed" }
    public var domain: String { "Tokens" }
    public var title: String { "A token could not be read" }
    public var body: String { "The token is malformed: \(reason)." }
  }

  /// Splits a token into its three segments and decodes them. Reads no JSON.
  ///
  /// Exactly three segments, none empty: `split` with its default drops an empty one, which
  /// would read `a..b` as two segments rather than refusing it.
  public init(parsing token: String) throws {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3 else {
      throw Malformed(reason: "expected 3 segments, got \(segments.count)")
    }
    guard let header = Base64URL.decode(String(segments[0])), !header.isEmpty,
      let claims = Base64URL.decode(String(segments[1])), !claims.isEmpty,
      let signature = Base64URL.decode(String(segments[2])), !signature.isEmpty
    else { throw Malformed(reason: "a segment is not base64url") }
    self.signingInput = Data("\(segments[0]).\(segments[1])".utf8)
    self.header = header
    self.claims = claims
    self.signature = signature
  }

  /// The claims, once `isValid` has accepted the signature and the header names `algorithm`.
  ///
  /// - Parameter isValid: the caller's own check of `signature` over `signingInput`.
  /// - Throws: `invalidSignature` when the signature is not accepted, and `Malformed` for a
  ///   header naming another algorithm. Signature first: see the file header.
  public func verifiedClaims(
    algorithm: String, invalidSignature: @autoclosure () -> any Error,
    isValid: (_ signature: Data, _ signingInput: Data) -> Bool
  ) throws -> Data {
    guard isValid(signature, signingInput) else { throw invalidSignature() }
    let object = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any]
    guard let named = object?["alg"] as? String, named == algorithm else {
      throw Malformed(reason: "the header does not name \(algorithm)")
    }
    return claims
  }
}
