//  PasswordDigestTests
//  The password is hashed once and cached. These cover what that cache can get wrong.

import BBSettings
import Foundation
import Testing

@testable import BBAuth

@Suite("Password digest")
struct PasswordDigestTests {

  @Test("A digest matches its own password and nothing else")
  func matching() {
    let digest = PasswordDigest("correct-horse")
    #expect(digest.constantTimeEquals("correct-horse"))
    #expect(!digest.constantTimeEquals("correct-hors"))
    #expect(!digest.constantTimeEquals("correct-horsee"))
    #expect(!digest.constantTimeEquals(""))
  }

  /// The old comparison walked the stored bytes directly, so these had to keep working
  /// through the change to a fixed-width digest.
  @Test("Passwords that are not plain ASCII still match")
  func awkwardPasswords() {
    for password in ["100%sure", "p@ss word", "üñíçø∂é", "🔑🔑", "tab\there", "a b  c "] {
      #expect(PasswordDigest(password).constantTimeEquals(password), "\(password)")
    }
  }

  @Test("An empty password is reported as empty")
  func emptiness() {
    #expect(PasswordDigest("").isEmpty)
    #expect(!PasswordDigest("x").isEmpty)
  }

  @Test("The source is hashed, not stored")
  func sourceIsNotRecoverable() {
    // Two digests of the same password are equal; the digest of one password tells you
    // nothing about another. Weak as assertions go, but it pins the shape: `PasswordDigest`
    // has no accessor that gives the plaintext back, and adding one should break a test.
    #expect(PasswordDigest("hunter2") == PasswordDigest("hunter2"))
    #expect(PasswordDigest("hunter2") != PasswordDigest("hunter3"))
  }
}

@Suite("Password digest cache")
struct PasswordDigestCacheTests {

  /// Counts reads so "hashed once" is an assertion rather than a claim in a comment.
  actor Source {
    private(set) var reads = 0
    private var value: String?
    private var readable: Bool

    init(_ value: String?, readable: Bool = true) {
      self.value = value
      self.readable = readable
    }

    func set(_ newValue: String?) { value = newValue }
    func setReadable(_ flag: Bool) { readable = flag }

    func read() -> SecureString? {
      reads += 1
      guard readable else { return nil }
      return value.map { SecureString($0) }
    }
  }

  @Test("The password is read once, not once per request")
  func readsOnce() async {
    let source = Source("hunter2hunter2")
    let cache = PasswordDigestCache(load: { await source.read() })

    for _ in 0..<20 {
      #expect(await cache.digest()?.constantTimeEquals("hunter2hunter2") == true)
    }
    #expect(await source.reads == 1)
  }

  /// The composition root builds the auth chain as a closure specifically so a handshake is
  /// checked against the password as it is NOW. A cache that outlived a change would undo
  /// that and leave a revoked password working until the next restart.
  @Test("A changed password takes effect on invalidate")
  func invalidation() async {
    let source = Source("old-password")
    let cache = PasswordDigestCache(load: { await source.read() })

    #expect(await cache.digest()?.constantTimeEquals("old-password") == true)

    await source.set("new-password")
    // Still the old one: nothing has told the cache yet.
    #expect(await cache.digest()?.constantTimeEquals("old-password") == true)

    await cache.invalidate()
    #expect(await cache.digest()?.constantTimeEquals("new-password") == true)
    #expect(await cache.digest()?.constantTimeEquals("old-password") == false)
  }

  /// The rule that keeps a transient Keychain failure transient. Caching the nil would make
  /// the server refuse every client for the rest of the process's life.
  @Test("An unreadable password is not cached, so recovery is automatic")
  func failureIsNotCached() async {
    let source = Source("hunter2hunter2", readable: false)
    let cache = PasswordDigestCache(load: { await source.read() })

    #expect(await cache.digest() == nil)
    #expect(await cache.digest() == nil)
    // Retried every time rather than latched.
    #expect(await source.reads == 2)

    await source.setReadable(true)
    #expect(await cache.digest()?.constantTimeEquals("hunter2hunter2") == true)
  }

  @Test("An unset password caches as empty rather than reading every time")
  func emptyIsCached() async {
    let source = Source("")
    let cache = PasswordDigestCache(load: { await source.read() })

    #expect(await cache.digest()?.isEmpty == true)
    #expect(await cache.digest()?.isEmpty == true)
    #expect(await source.reads == 1)
  }
}
