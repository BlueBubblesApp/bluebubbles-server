//  GoogleAuthTests
//  The service-account JWT.
//
//  This is the piece with the worst failure mode in the module: get it subtly wrong and
//  nothing fails locally — Google simply refuses every token, and push stops working for
//  reasons that look like a network problem. So the signature is verified against a DIFFERENT
//  implementation than the one that produced it: swift-crypto (BoringSSL) signs,
//  Security.framework (corecrypto) verifies. Two libraries agreeing is evidence; one library
//  round-tripping itself is not.
//
//  The key here is generated per-run and thrown away. No real credential ever appears in a
//  test — see CONTRIBUTING.md.

import Foundation
import Security
import Testing

@testable import BBPushKit

/// A throwaway 2048-bit RSA key, generated fresh for each run.
enum TestKey {

  /// Generated with Security.framework so the test carries no key material of its own.
  static func makePEM() throws -> (pem: String, publicKey: SecKey) {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 2048,
    ]
    var error: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      throw TestKeyError.generationFailed
    }
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
      throw TestKeyError.generationFailed
    }
    guard let raw = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
      throw TestKeyError.generationFailed
    }

    // SecKey gives PKCS#1; Google issues PKCS#8, which is what the parser expects. Wrap
    // it so the test exercises the same path a real credential takes.
    let pem = pkcs8PEM(fromPKCS1: raw)
    return (pem, publicKey)
  }

  /// Wraps a PKCS#1 RSA key in the PKCS#8 envelope, by prefixing the fixed
  /// AlgorithmIdentifier for rsaEncryption. Fixed because the algorithm never varies here.
  private static func pkcs8PEM(fromPKCS1 pkcs1: Data) -> String {
    let algorithmIdentifier: [UInt8] = [
      0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
      0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
    ]
    var inner = Data([0x04])  // OCTET STRING
    inner.append(contentsOf: derLength(pkcs1.count))
    inner.append(pkcs1)

    var body = Data([0x02, 0x01, 0x00])  // version 0
    body.append(contentsOf: algorithmIdentifier)
    body.append(inner)

    var der = Data([0x30])  // SEQUENCE
    der.append(contentsOf: derLength(body.count))
    der.append(body)

    let base64 = der.base64EncodedString()
    let lines = stride(from: 0, to: base64.count, by: 64).map { offset -> String in
      let start = base64.index(base64.startIndex, offsetBy: offset)
      let end = base64.index(start, offsetBy: min(64, base64.count - offset))
      return String(base64[start..<end])
    }
    return "-----BEGIN PRIVATE KEY-----\n"
      + lines.joined(separator: "\n")
      + "\n-----END PRIVATE KEY-----\n"
  }

  private static func derLength(_ length: Int) -> [UInt8] {
    if length < 0x80 { return [UInt8(length)] }
    var bytes: [UInt8] = []
    var remaining = length
    while remaining > 0 {
      bytes.insert(UInt8(remaining & 0xFF), at: 0)
      remaining >>= 8
    }
    return [UInt8(0x80 | bytes.count)] + bytes
  }

  enum TestKeyError: Error { case generationFailed }
}

private func account(privateKey: String) -> ServiceAccount {
  ServiceAccount(
    projectId: "bluebubbles-test",
    privateKeyId: "test-key-id",
    privateKey: privateKey,
    clientEmail: "test@bluebubbles-test.iam.gserviceaccount.com"
  )
}

/// base64url -> Data, for decoding the JWT the code produced.
private func decodeBase64URL(_ text: String) -> Data? {
  var padded =
    text
    .replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  while padded.count % 4 != 0 { padded += "=" }
  return Data(base64Encoded: padded)
}

@Suite("Service account JWT")
struct GoogleAuthTests {

  /// The claim set Google requires, exactly. Extra or missing claims are rejected at the
  /// token endpoint, not here.
  @Test("The assertion carries the five required claims")
  func claimShape() throws {
    let key = try TestKey.makePEM()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let assertion = try GoogleTokenProvider.assertion(
      for: account(privateKey: key.pem),
      scopes: [GoogleScope.firebaseMessaging],
      now: now
    )

    let parts = assertion.split(separator: ".")
    #expect(parts.count == 3)

    let claimData = try #require(decodeBase64URL(String(parts[1])))
    let object = try #require(
      try JSONSerialization.jsonObject(with: claimData) as? [String: Any]
    )

    #expect(object["iss"] as? String == "test@bluebubbles-test.iam.gserviceaccount.com")
    #expect(object["aud"] as? String == "https://oauth2.googleapis.com/token")
    #expect(object["scope"] as? String == GoogleScope.firebaseMessaging)
    #expect(object["iat"] as? Int == 1_700_000_000)
    // One hour is Google's maximum.
    #expect(object["exp"] as? Int == 1_700_000_000 + 3600)
  }

  @Test("The header declares RS256 and names the key")
  func headerShape() throws {
    let key = try TestKey.makePEM()
    let assertion = try GoogleTokenProvider.assertion(
      for: account(privateKey: key.pem), scopes: [GoogleScope.firebaseMessaging]
    )
    let headerData = try #require(
      decodeBase64URL(String(assertion.split(separator: ".")[0]))
    )
    let header = try #require(
      try JSONSerialization.jsonObject(with: headerData) as? [String: Any]
    )
    #expect(header["alg"] as? String == "RS256")
    #expect(header["typ"] as? String == "JWT")
    // Google uses `kid` to select which of the account's keys to verify with; omitting it
    // works until the key is rotated and then silently stops.
    #expect(header["kid"] as? String == "test-key-id")
  }

  /// The test that matters. Signed by swift-crypto, verified by Security.framework — two
  /// independent implementations of RSASSA-PKCS1-v1_5.
  @Test("The signature verifies under an independent implementation")
  func signatureVerifiesCrossImplementation() throws {
    let key = try TestKey.makePEM()
    let assertion = try GoogleTokenProvider.assertion(
      for: account(privateKey: key.pem), scopes: GoogleScope.serverRuntime
    )

    let parts = assertion.split(separator: ".")
    let signingInput = "\(parts[0]).\(parts[1])"
    let signature = try #require(decodeBase64URL(String(parts[2])))

    var error: Unmanaged<CFError>?
    let verified = SecKeyVerifySignature(
      key.publicKey,
      .rsaSignatureMessagePKCS1v15SHA256,
      Data(signingInput.utf8) as CFData,
      signature as CFData,
      &error
    )
    #expect(verified, "RS256 signature did not verify: \(String(describing: error))")
  }

  /// A tampered payload must not verify — otherwise the previous test proves only that
  /// bytes were produced.
  @Test("A tampered assertion fails verification")
  func tamperedAssertionFails() throws {
    let key = try TestKey.makePEM()
    let assertion = try GoogleTokenProvider.assertion(
      for: account(privateKey: key.pem), scopes: GoogleScope.serverRuntime
    )
    let parts = assertion.split(separator: ".")
    let signature = try #require(decodeBase64URL(String(parts[2])))

    // Same signature, different claims.
    let tampered = "\(parts[0]).\(GoogleTokenProvider.base64URL(Data(#"{"iss":"attacker"}"#.utf8)))"
    var error: Unmanaged<CFError>?
    let verified = SecKeyVerifySignature(
      key.publicKey,
      .rsaSignatureMessagePKCS1v15SHA256,
      Data(tampered.utf8) as CFData,
      signature as CFData,
      &error
    )
    #expect(!verified)
  }

  /// JWT uses base64url without padding. Plain base64 is silently accepted by some parsers
  /// and rejected by Google's.
  @Test("Encoding is base64url and unpadded")
  func base64URLEncoding() {
    // Bytes chosen to produce both + and / in standard base64.
    let data = Data([0xFB, 0xEF, 0xFF, 0x00])
    let encoded = GoogleTokenProvider.base64URL(data)
    #expect(!encoded.contains("+"))
    #expect(!encoded.contains("/"))
    #expect(!encoded.contains("="))
  }

  @Test("A key that is not a valid PEM is reported as such")
  func invalidKeyIsReported() {
    #expect(throws: GoogleAuthError.self) {
      _ = try GoogleTokenProvider.assertion(
        for: account(
          privateKey: "-----BEGIN PRIVATE KEY-----\nnonsense\n-----END PRIVATE KEY-----"),
        scopes: []
      )
    }
  }
}

@Suite("Token caching")
struct TokenCachingTests {

  /// Counts exchanges, so coalescing can be observed rather than assumed.
  private actor CountingExchanger: TokenExchanging {
    private(set) var calls = 0
    let lifetime: TimeInterval
    init(lifetime: TimeInterval = 3600) { self.lifetime = lifetime }

    func exchange(assertion: String, tokenURI: String) async throws -> AccessToken {
      calls += 1
      // A beat, so concurrent callers actually overlap.
      try await Task.sleep(for: .milliseconds(20))
      return AccessToken(
        value: "token-\(calls)", expiresAt: Date().addingTimeInterval(lifetime)
      )
    }
    func callCount() -> Int { calls }
  }

  @Test("A cached token is reused")
  func reusesCachedToken() async throws {
    let key = try TestKey.makePEM()
    let exchanger = CountingExchanger()
    let provider = GoogleTokenProvider(
      account: account(privateKey: key.pem), exchanger: exchanger
    )

    let first = try await provider.token()
    let second = try await provider.token()
    #expect(first.value == second.value)
    #expect(await exchanger.callCount() == 1)
  }

  /// Without coalescing, a burst of notifications on a cold cache mints a JWT and hits the
  /// token endpoint once per notification.
  @Test("Concurrent callers share one token request")
  func coalescesConcurrentRefreshes() async throws {
    let key = try TestKey.makePEM()
    let exchanger = CountingExchanger()
    let provider = GoogleTokenProvider(
      account: account(privateKey: key.pem), exchanger: exchanger
    )

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<10 {
        group.addTask { _ = try? await provider.token() }
      }
    }
    #expect(await exchanger.callCount() == 1)
  }

  /// Refreshed before expiry, not at it: a token that dies mid-flight surfaces as a
  /// delivery failure rather than as an auth problem.
  @Test("A token near expiry is replaced early")
  func refreshesBeforeExpiry() async throws {
    let key = try TestKey.makePEM()
    // Shorter than the 300-second leeway, so it is never considered usable.
    let exchanger = CountingExchanger(lifetime: 60)
    let provider = GoogleTokenProvider(
      account: account(privateKey: key.pem), exchanger: exchanger
    )

    _ = try await provider.token()
    _ = try await provider.token()
    #expect(await exchanger.callCount() == 2)
  }

  @Test("Invalidating forces a fresh mint")
  func invalidateForcesRefresh() async throws {
    let key = try TestKey.makePEM()
    let exchanger = CountingExchanger()
    let provider = GoogleTokenProvider(
      account: account(privateKey: key.pem), exchanger: exchanger
    )

    _ = try await provider.token()
    await provider.invalidate()
    _ = try await provider.token()
    #expect(await exchanger.callCount() == 2)
  }

  @Test("Usability accounts for the refresh leeway")
  func usabilityLeeway() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(AccessToken(value: "t", expiresAt: now.addingTimeInterval(3600)).isUsable(at: now))
    // Inside the 300-second leeway.
    #expect(!AccessToken(value: "t", expiresAt: now.addingTimeInterval(120)).isUsable(at: now))
    #expect(!AccessToken(value: "t", expiresAt: now.addingTimeInterval(-1)).isUsable(at: now))
  }
}
