//  SemanticVersionTests
//
//  The ordering here is the difference between a server that receives updates and one that
//  sits unpatched. String comparison puts 1.10.0 BELOW 1.9.0, so a lexical check stops
//  offering updates permanently at the tenth minor release — with no error anywhere.

import BBCore
import Testing

@testable import BBUpdates

@Suite("SemanticVersion")
struct SemanticVersionTests {

  @Test("parses the forms that actually appear")
  func parsing() {
    #expect(SemanticVersion("1.2.3").description == "1.2.3")
    // Tags carry a leading v.
    #expect(SemanticVersion("v1.2.3").description == "1.2.3")
    // A missing patch is common in CFBundleVersion.
    #expect(SemanticVersion("1.2").description == "1.2.0")
    #expect(SemanticVersion("2").description == "2.0.0")
    #expect(SemanticVersion("  1.2.3  ").description == "1.2.3")
    #expect(SemanticVersion("1.2.3-beta.1").description == "1.2.3-beta.1")
    // Build metadata is not part of precedence.
    #expect(SemanticVersion("1.2.3+abc123").description == "1.2.3")
  }

  /// The specific case that breaks lexical comparison.
  @Test("ten sorts above nine")
  func doubleDigits() {
    #expect(SemanticVersion("1.9.0") < SemanticVersion("1.10.0"))
    #expect(SemanticVersion("1.2.9") < SemanticVersion("1.2.10"))
    #expect(SemanticVersion("9.0.0") < SemanticVersion("10.0.0"))
    // And confirm the naive comparison really would get it wrong, so this test is
    // pinning a real difference rather than an arbitrary one.
    #expect("1.10.0" < "1.9.0")
  }

  @Test("orders by major, then minor, then patch")
  func ordering() {
    #expect(SemanticVersion("1.0.0") < SemanticVersion("2.0.0"))
    #expect(SemanticVersion("1.1.0") < SemanticVersion("1.2.0"))
    #expect(SemanticVersion("1.1.1") < SemanticVersion("1.1.2"))
    #expect(SemanticVersion("2.0.0") > SemanticVersion("1.99.99"))
  }

  /// A prerelease precedes its release, so shipping 1.2.0 still reaches someone on
  /// 1.2.0-beta.1 rather than looking like the same version.
  @Test("a prerelease sorts before its release")
  func prerelease() {
    #expect(SemanticVersion("1.2.0-beta.1") < SemanticVersion("1.2.0"))
    #expect(SemanticVersion("1.2.0-beta.1") < SemanticVersion("1.2.0-beta.2"))
    // Numeric, not lexical, inside the suffix too.
    #expect(SemanticVersion("1.2.0-beta.9") < SemanticVersion("1.2.0-beta.10"))
    #expect(SemanticVersion("1.2.0-beta.1") > SemanticVersion("1.1.9"))
  }

  @Test("equal versions are equal")
  func equality() {
    #expect(SemanticVersion("1.2.3") == SemanticVersion("v1.2.3"))
    #expect(!(SemanticVersion("1.2.3") < SemanticVersion("1.2.3")))
    #expect(!(SemanticVersion("1.2.3") > SemanticVersion("1.2.3")))
  }

  /// Garbage sorts lowest rather than throwing. A malformed appcast entry must not be
  /// offered as an update, and it must not break the check for the valid entries beside it.
  @Test("unparseable input sorts lowest")
  func garbage() {
    #expect(SemanticVersion("") == SemanticVersion(major: 0, minor: 0, patch: 0))
    #expect(SemanticVersion("not-a-version") < SemanticVersion("0.0.1"))
    #expect(SemanticVersion("1.2.3") > SemanticVersion("garbage"))
  }
}
