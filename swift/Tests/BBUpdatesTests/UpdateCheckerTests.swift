//  UpdateCheckerTests
//
//  The response shape here is a compatibility contract — clients read `available`, `current`,
//  and four fields inside `metadata`, which must be explicitly `null` rather than absent when
//  there is nothing to offer. See `CONTRIBUTING.md`.

import BBSerialization
import Foundation
import Testing

@testable import BBUpdates

@Suite("UpdateChecker")
struct UpdateCheckerTests {

  private func feed(_ versions: [String], notes: String? = nil) -> Data {
    let items = versions.map { version in
      AppcastItem(
        shortVersion: version,
        version: version,
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        releaseNotesHTML: notes,
        downloadURL: "https://example.com/BlueBubbles-\(version).dmg",
        lengthInBytes: 2048,
        edSignature: "sig"
      )
    }
    return Data(Appcast(items: items).xmlString().utf8)
  }

  private func checker(current: String, feed data: Data) -> UpdateChecker {
    UpdateChecker(
      feedURL: "https://example.invalid/appcast.xml",
      currentVersion: current,
      fetch: { _ in data }
    )
  }

  @Test("a newer release is offered")
  func available() async throws {
    let result = try await checker(current: "1.2.0", feed: feed(["1.3.0"])).check()
    #expect(result.isAvailable)
    #expect(result.item?.shortVersion == "1.3.0")
  }

  @Test("the same version is not offered")
  func upToDate() async throws {
    let result = try await checker(current: "1.3.0", feed: feed(["1.3.0"])).check()
    #expect(!result.isAvailable)
    #expect(result.item == nil)
  }

  /// A server ahead of the feed — a local build, or a rolled-back release — must not be
  /// offered a downgrade.
  @Test("an older release is not offered")
  func downgrade() async throws {
    let result = try await checker(current: "2.0.0", feed: feed(["1.9.0"])).check()
    #expect(!result.isAvailable)
  }

  /// The case string comparison gets wrong. A server on 1.9.0 must be offered 1.10.0.
  @Test("1.10.0 is offered to 1.9.0")
  func doubleDigitMinor() async throws {
    let result = try await checker(current: "1.9.0", feed: feed(["1.10.0"])).check()
    #expect(result.isAvailable, "a lexical comparison would have missed this")
    #expect(result.item?.shortVersion == "1.10.0")
  }

  @Test("the newest entry wins when the feed has several")
  func picksNewest() async throws {
    let result = try await checker(
      current: "1.0.0", feed: feed(["1.2.0", "2.1.0", "1.9.0"])
    ).check()
    #expect(result.item?.shortVersion == "2.1.0")
  }

  @Test("an empty feed reports no update")
  func emptyFeed() async throws {
    let data = Data(Appcast(items: []).xmlString().utf8)
    let result = try await checker(current: "1.0.0", feed: data).check()
    #expect(!result.isAvailable)
    #expect(result.item == nil)
  }

  // MARK: - The wire contract

  @Test("metadata is explicit null when there is no update")
  func nullMetadata() async throws {
    let json = try await checker(current: "1.3.0", feed: feed(["1.3.0"])).check().json

    #expect(json["available"]?.boolValue == false)
    #expect(json["current"]?.stringValue == "1.3.0")
    // Present AND null. A strict client distinguishes that from absent, and the current
    // server emits null here.
    #expect(json.objectKeys.contains("metadata"))
    #expect(json["metadata"]?.isNull == true)
  }

  @Test("metadata carries all four fields when there is one")
  func metadataShape() async throws {
    let json = try await checker(
      current: "1.2.0", feed: feed(["1.3.0"], notes: "<p>Fixes</p>")
    ).check().json

    #expect(json["available"]?.boolValue == true)
    #expect(json["current"]?.stringValue == "1.2.0")

    let metadata = try #require(json["metadata"])
    #expect(metadata.objectKeys == ["version", "release_date", "release_name", "release_notes"])
    #expect(metadata["version"]?.stringValue == "1.3.0")
    #expect(metadata["release_name"]?.stringValue == "1.3.0")
    #expect(metadata["release_notes"]?.stringValue == "<p>Fixes</p>")

    // ISO 8601 here specifically — the one date on the wire that is not epoch
    // milliseconds, matching what electron-updater emitted.
    let date = try #require(metadata["release_date"]?.stringValue)
    #expect(ISO8601DateFormatter().date(from: date) == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("release_notes is null rather than absent when the entry has none")
  func missingNotes() async throws {
    let json = try await checker(current: "1.2.0", feed: feed(["1.3.0"])).check().json
    let metadata = try #require(json["metadata"])
    #expect(metadata.objectKeys.contains("release_notes"))
    #expect(metadata["release_notes"]?.isNull == true)
  }

  @Test("a malformed feed is an error rather than a false 'up to date'")
  func malformedFeed() async {
    let checker = UpdateChecker(
      feedURL: "https://example.invalid/appcast.xml",
      currentVersion: "1.0.0",
      fetch: { _ in Data("<rss><channel><item>".utf8) }
    )
    // Reporting "no update" for an unreadable feed would hide a broken release pipeline
    // indefinitely.
    await #expect(throws: AppcastParser.ParseError.self) { try await checker.check() }
  }
}
