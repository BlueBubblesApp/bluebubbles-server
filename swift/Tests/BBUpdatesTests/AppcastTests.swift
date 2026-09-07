//  AppcastTests
//
//  These pin the feed format because every failure in it is silent. A malformed appcast, a
//  wrong namespace prefix, a truncated release note, a signature over the wrong bytes — each
//  produces a release that looks correct to whoever cut it and that shipped installs quietly
//  refuse. The symptom appears weeks later as "nobody is getting updates", with nothing in
//  any log to point at.
//
//  Every URL and version here is synthetic.

import Crypto
import Foundation
import Testing

@testable import BBUpdates

@Suite("Appcast")
struct AppcastTests {

  private func item(
    _ shortVersion: String,
    signature: String = "AAAA",
    notes: String? = nil
  ) -> AppcastItem {
    AppcastItem(
      shortVersion: shortVersion,
      version: shortVersion,
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      releaseNotesHTML: notes,
      downloadURL: "https://example.com/BlueBubbles-\(shortVersion).dmg",
      lengthInBytes: 1024,
      edSignature: signature
    )
  }

  // MARK: - Round trip

  @Test("a written feed parses back to what went in")
  func roundTrip() throws {
    let original = Appcast(
      title: "BlueBubbles Server",
      link: "https://example.com",
      description: "Updates",
      items: [item("1.2.3"), item("1.3.0")]
    )
    let parsed = try AppcastParser.parse(Data(original.xmlString().utf8))

    #expect(parsed.title == "BlueBubbles Server")
    #expect(parsed.items.count == 2)

    let newest = try #require(parsed.newestItem)
    #expect(newest.shortVersion == "1.3.0")
    #expect(newest.downloadURL == "https://example.com/BlueBubbles-1.3.0.dmg")
    #expect(newest.lengthInBytes == 1024)
    #expect(newest.edSignature == "AAAA")
    #expect(newest.minimumSystemVersion == "14.0")
  }

  /// Sparkle looks for `sparkle:` bound to that exact namespace URI. A generator that
  /// invented its own prefix produces valid XML that Sparkle reads as an empty feed.
  @Test("the sparkle namespace is declared exactly as Sparkle expects")
  func namespace() {
    let xml = Appcast(items: [item("1.0.0")]).xmlString()
    #expect(
      xml.contains(
        #"xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle""#
      ))
    #expect(xml.contains("<sparkle:version>"))
    #expect(xml.contains("<sparkle:shortVersionString>"))
    #expect(xml.contains("sparkle:edSignature="))
    #expect(xml.hasPrefix(#"<?xml version="1.0" encoding="utf-8"?>"#))
  }

  /// `newestItem` must not depend on position. An appcast that accumulated entries out of
  /// order would otherwise offer an older build, which Sparkle then refuses to install —
  /// leaving users stuck with no explanation.
  @Test("the newest item is found regardless of order")
  func newestIsByVersion() {
    let feed = Appcast(items: [item("1.10.0"), item("1.9.0"), item("1.2.0")])
    #expect(feed.newestItem?.shortVersion == "1.10.0")

    let reversed = Appcast(items: [item("1.2.0"), item("1.9.0"), item("1.10.0")])
    #expect(reversed.newestItem?.shortVersion == "1.10.0")

    #expect(Appcast(items: []).newestItem == nil)
  }

  @Test("items are written newest first")
  func writeOrder() throws {
    let xml = Appcast(items: [item("1.2.0"), item("2.0.0"), item("1.9.0")]).xmlString()
    let first = try #require(xml.range(of: "<title>2.0.0</title>"))
    let second = try #require(xml.range(of: "<title>1.9.0</title>"))
    #expect(first.lowerBound < second.lowerBound)
  }

  // MARK: - Escaping

  @Test("special characters in values are escaped")
  func escaping() throws {
    var entry = item("1.0.0")
    entry.downloadURL = "https://example.com/a.dmg?x=1&y=2"
    entry.title = "Release <1.0.0> & \"friends\""

    let parsed = try AppcastParser.parse(Data(Appcast(items: [entry]).xmlString().utf8))
    let newest = try #require(parsed.newestItem)
    #expect(newest.downloadURL == "https://example.com/a.dmg?x=1&y=2")
    #expect(newest.title == "Release <1.0.0> & \"friends\"")
  }

  /// A release note containing `]]>` would otherwise close the CDATA section early and
  /// produce invalid XML — from ordinary prose in a changelog.
  @Test("a release note cannot break out of its CDATA section")
  func cdataEscape() throws {
    let notes = "<p>Fixed the <code>a[b]]>c</code> case.</p>"
    let feed = Appcast(items: [item("1.0.0", notes: notes)])

    let parsed = try AppcastParser.parse(Data(feed.xmlString().utf8))
    #expect(parsed.items.count == 1, "the feed did not parse; CDATA was terminated early")
    #expect(parsed.newestItem?.releaseNotesHTML == notes)
  }

  /// XMLParser hands text through in arbitrary chunks, so a long body arrives across
  /// several callbacks. Assigning instead of appending truncates it to the last fragment.
  @Test("a long release note survives chunked parsing")
  func longNotes() throws {
    let notes = "<p>" + String(repeating: "detailed changelog text. ", count: 500) + "</p>"
    let feed = Appcast(items: [item("1.0.0", notes: notes)])

    let parsed = try AppcastParser.parse(Data(feed.xmlString().utf8))
    #expect(parsed.newestItem?.releaseNotesHTML == notes)
  }

  /// The date format is pinned to en_US_POSIX and UTC. Without that it follows the build
  /// machine's locale, and a release cut on a French-configured machine emits `mer.` for
  /// Wednesday, which every RSS reader rejects.
  @Test("dates are RFC 822 regardless of the machine's locale")
  func dateFormat() throws {
    let feed = Appcast(items: [item("1.0.0")])
    let xml = feed.xmlString()
    #expect(xml.contains("<pubDate>Tue, 14 Nov 2023 22:13:20 +0000</pubDate>"))

    let parsed = try AppcastParser.parse(Data(xml.utf8))
    #expect(parsed.newestItem?.publishedAt == Date(timeIntervalSince1970: 1_700_000_000))
  }

  // MARK: - Malformed input

  @Test("malformed XML is an error, not an empty feed")
  func malformed() {
    #expect(throws: AppcastParser.ParseError.self) {
      try AppcastParser.parse(Data("<rss><channel><item>".utf8))
    }
  }

  /// A partial entry is skipped rather than offered. Sparkle would show it and then fail
  /// at install, which is worse than never mentioning it.
  @Test("an entry with no download is skipped")
  func incompleteItem() throws {
    let xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel>
          <title>Feed</title>
          <item>
            <sparkle:version>9.9.9</sparkle:version>
          </item>
          <item>
            <sparkle:version>1.0.0</sparkle:version>
            <enclosure url="https://example.com/a.dmg" length="10"
                       type="application/octet-stream" sparkle:edSignature="sig" />
          </item>
        </channel>
      </rss>
      """
    let parsed = try AppcastParser.parse(Data(xml.utf8))
    #expect(parsed.items.count == 1)
    #expect(parsed.newestItem?.shortVersion == "1.0.0")
  }

  /// An item with no `shortVersionString` falls back to `version`, because older
  /// generators emit only one of the two.
  @Test("shortVersionString falls back to version")
  func versionFallback() throws {
    let xml = """
      <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel><item>
          <sparkle:version>3.4.5</sparkle:version>
          <enclosure url="https://example.com/a.dmg" length="10"
                     type="application/octet-stream" sparkle:edSignature="sig" />
        </item></channel>
      </rss>
      """
    let parsed = try AppcastParser.parse(Data(xml.utf8))
    #expect(parsed.newestItem?.shortVersion == "3.4.5")
  }
}

@Suite("Appcast signing")
struct AppcastSigningTests {

  /// A deterministic key, so these do not depend on key generation. Synthetic — it signs
  /// nothing real.
  private func testKey() -> Curve25519.Signing.PrivateKey {
    try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
  }

  @Test("a signature verifies against its own key")
  func signAndVerify() throws {
    let key = testKey()
    let payload = Data("a pretend disk image".utf8)
    let signature = try AppcastSigning.signature(for: payload, privateKey: key)

    #expect(
      AppcastSigning.isValid(
        signature: signature, for: payload, publicKey: key.publicKey
      ))
  }

  /// The failure this exists to catch: a signature over the wrong bytes. It is
  /// indistinguishable from a correct one by inspection, and it silently disables updates
  /// for everyone.
  @Test("a signature does not verify against different bytes")
  func wrongPayload() throws {
    let key = testKey()
    let signature = try AppcastSigning.signature(for: Data("original".utf8), privateKey: key)

    #expect(
      !AppcastSigning.isValid(
        signature: signature, for: Data("tampered".utf8), publicKey: key.publicKey
      ))
    // A single flipped byte, which is what a corrupted upload looks like.
    #expect(
      !AppcastSigning.isValid(
        signature: signature, for: Data("originaL".utf8), publicKey: key.publicKey
      ))
  }

  @Test("a signature does not verify against a different key")
  func wrongKey() throws {
    let payload = Data("artifact".utf8)
    let signature = try AppcastSigning.signature(for: payload, privateKey: testKey())
    let other = try Curve25519.Signing.PrivateKey(
      rawRepresentation: Data(repeating: 0x43, count: 32)
    )
    #expect(
      !AppcastSigning.isValid(
        signature: signature, for: payload, publicKey: other.publicKey
      ))
  }

  /// Sparkle's `generate_keys` exports 64 bytes — a 32-byte seed followed by the public
  /// key. Feeding all 64 to swift-crypto fails, so the tail is dropped. Both forms are
  /// accepted because pasting either is an easy mistake with no distinguishing symptom.
  @Test("both Sparkle key export lengths load")
  func keyLengths() throws {
    let seed = Data(repeating: 0x42, count: 32)
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let libsodiumForm = seed + key.publicKey.rawRepresentation

    let fromSeed = try AppcastSigning.privateKey(fromBase64: seed.base64EncodedString())
    let fromExport = try AppcastSigning.privateKey(
      fromBase64: libsodiumForm.base64EncodedString()
    )
    #expect(fromSeed.publicKey.rawRepresentation == fromExport.publicKey.rawRepresentation)
    #expect(fromSeed.publicKey.rawRepresentation == key.publicKey.rawRepresentation)
  }

  @Test("a bad key is rejected with a reason")
  func badKeys() {
    #expect(throws: AppcastSigning.SigningError.self) {
      try AppcastSigning.privateKey(fromBase64: "not base64!!")
    }
    #expect(throws: AppcastSigning.SigningError.self) {
      try AppcastSigning.privateKey(
        fromBase64: Data(repeating: 0, count: 17).base64EncodedString()
      )
    }
    #expect(throws: AppcastSigning.SigningError.self) {
      try AppcastSigning.publicKey(fromBase64: "AAAA")
    }
  }

  @Test("whitespace around a key is tolerated")
  func whitespace() throws {
    // Secrets pasted into CI pick up trailing newlines constantly.
    let encoded = Data(repeating: 0x42, count: 32).base64EncodedString()
    let key = try AppcastSigning.privateKey(fromBase64: "  \(encoded)\n")
    #expect(key.publicKey.rawRepresentation == testKey().publicKey.rawRepresentation)
  }

  @Test("the public key round-trips through its base64 form")
  func publicKeyRoundTrip() throws {
    let key = testKey()
    let encoded = AppcastSigning.publicKeyBase64(for: key)
    let decoded = try AppcastSigning.publicKey(fromBase64: encoded)
    #expect(decoded.rawRepresentation == key.publicKey.rawRepresentation)
  }

  /// End to end: sign an artifact, put it in a feed, read the feed back, and verify the
  /// signature that survived the round trip. This is the whole release path in miniature.
  @Test("a signature survives the appcast round trip")
  func endToEnd() throws {
    let key = testKey()
    let artifact = Data((0..<4096).map { UInt8($0 % 256) })
    let signature = try AppcastSigning.signature(for: artifact, privateKey: key)

    let feed = Appcast(items: [
      AppcastItem(
        shortVersion: "1.4.0", version: "1.4.0",
        downloadURL: "https://example.com/BlueBubbles-1.4.0.dmg",
        lengthInBytes: artifact.count,
        edSignature: signature
      )
    ])
    let parsed = try AppcastParser.parse(Data(feed.xmlString().utf8))
    let newest = try #require(parsed.newestItem)

    #expect(newest.lengthInBytes == artifact.count)
    #expect(
      AppcastSigning.isValid(
        signature: newest.edSignature, for: artifact, publicKey: key.publicKey
      ))
  }
}
