//  FaceTimeLinkLedgerTests
//  The record that keeps cleanup off the user's own links.
//
//  The safety property under test is negative and unrecoverable if broken: a link the server
//  did not create must never become a deletion candidate. TelephonyUtilities cannot tell the
//  two apart — `locallyCreated` is true for both — so this ledger is the only thing standing
//  between "clear strays" and "delete a person's FaceTime link".
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBSystem
import Foundation
import Testing

@Suite("FaceTime link ledger")
struct FaceTimeLinkLedgerTests {

  private func temporaryPath() -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-ledger-\(UUID().uuidString).json").path
  }

  @Test("A recorded link is remembered, and survives a reload")
  func recordsAndPersists() async throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let ledger = FaceTimeLinkLedger(path: path)
    await ledger.record(url: "https://facetime.apple.com/join#a", groupUUID: "GROUP-1")
    #expect(await ledger.all().count == 1)

    // A second instance reads what the first wrote — cleanup runs after a restart.
    let reloaded = FaceTimeLinkLedger(path: path)
    let entries = await reloaded.all()
    #expect(entries.first?.url == "https://facetime.apple.com/join#a")
    #expect(entries.first?.groupUUID == "GROUP-1")
  }

  /// THE SAFETY PROPERTY. Only recorded links are ever candidates.
  @Test("A link the server never created is never a candidate")
  func untrackedLinksAreNeverCandidates() async throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let ledger = FaceTimeLinkLedger(path: path)
    await ledger.record(url: "https://facetime.apple.com/join#ours", groupUUID: nil)

    let candidates = await ledger.expired(olderThan: 0)
    #expect(candidates.map(\.url) == ["https://facetime.apple.com/join#ours"])
    #expect(!candidates.contains { $0.url.contains("theirs") })
  }

  @Test("Only links older than the TTL expire")
  func ttlSelectsOldLinks() async throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let ledger = FaceTimeLinkLedger(path: path)
    await ledger.record(url: "https://facetime.apple.com/join#fresh", groupUUID: nil)

    // Nothing is an hour old yet.
    #expect(await ledger.expired(olderThan: 3600).isEmpty)
    // Everything is, an hour from now.
    let later = Date().addingTimeInterval(7200)
    #expect(await ledger.expired(olderThan: 3600, now: later).count == 1)
  }

  /// A link that could NOT be invalidated stays on the list and is retried, rather than
  /// being forgotten and left stray forever.
  @Test("Only invalidated links are forgotten")
  func forgetsOnlyWhatWasInvalidated() async throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let ledger = FaceTimeLinkLedger(path: path)
    await ledger.record(url: "https://facetime.apple.com/join#done", groupUUID: nil)
    await ledger.record(url: "https://facetime.apple.com/join#failed", groupUUID: nil)

    await ledger.forget(urls: ["https://facetime.apple.com/join#done"])
    #expect(await ledger.all().map(\.url) == ["https://facetime.apple.com/join#failed"])
  }

  @Test("Recording the same link twice keeps one entry")
  func recordIsIdempotent() async throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let ledger = FaceTimeLinkLedger(path: path)
    await ledger.record(url: "https://facetime.apple.com/join#a", groupUUID: nil)
    await ledger.record(url: "https://facetime.apple.com/join#a", groupUUID: nil)
    #expect(await ledger.all().count == 1)
  }

  /// A corrupt ledger must not wedge the server — but it must not silently read as "no links
  /// exist" either, which would look like a clean slate while strays pile up. Reading it
  /// yields nothing AND leaves the server usable.
  @Test("A corrupt ledger degrades to empty rather than throwing")
  func corruptLedgerIsSurvivable() async throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try "not json at all".write(toFile: path, atomically: true, encoding: .utf8)

    let ledger = FaceTimeLinkLedger(path: path)
    #expect(await ledger.all().isEmpty)
    // Still writable afterwards.
    await ledger.record(url: "https://facetime.apple.com/join#new", groupUUID: nil)
    #expect(await ledger.all().count == 1)
  }
}
