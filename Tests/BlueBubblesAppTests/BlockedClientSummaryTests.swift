//  BlockedClientSummaryTests
//  The line under a blocked address on the Security page.
//
//  It read the clock directly while living on a View, so it was untestable twice over. The
//  interesting case is the boundary: a block whose expiry has just passed while its row is
//  still on screen.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAuth
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Blocked client summary")
struct BlockedClientSummaryTests {

  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  /// Built by DECODING rather than by an initialiser.
  ///
  /// `BlockedClient`'s memberwise init is internal to BBAuth, and widening a library's public
  /// surface so a test can construct a value is the wrong trade — the type is `Codable`, and
  /// decoding exercises the same shape the access-control store round-trips through anyway.
  private func client(
    failureCount: Int = 10,
    reason: String = "auth.invalid_credential",
    expiresIn: TimeInterval? = 900,
    offenceCount: Int = 1
  ) throws -> BlockedClient {
    // The default `Codable` date strategy: seconds since the reference date.
    let stamp = now.timeIntervalSinceReferenceDate
    var fields: [String] = [
      "\"id\": \"\(UUID().uuidString)\"",
      "\"address\": \"203.0.113.10\"",
      "\"reason\": \"\(reason)\"",
      "\"failureCount\": \(failureCount)",
      "\"firstSeen\": \(stamp)",
      "\"lastSeen\": \(stamp)",
      "\"blockedAt\": \(stamp)",
      "\"offenceCount\": \(offenceCount)",
    ]
    if let expiresIn { fields.append("\"expiresAt\": \(stamp + expiresIn)") }
    let json = "{" + fields.joined(separator: ",") + "}"
    return try JSONDecoder().decode(BlockedClient.self, from: Data(json.utf8))
  }

  @Test("An automatic block says how long is left")
  func expiringBlock() throws {
    let line = BlockedClientSummary.describe(try client(expiresIn: 900), now: now)
    #expect(line.contains("10 failed attempts"))
    #expect(line.contains("auth.invalid_credential"))
    #expect(line.contains("expires in"))
    #expect(!line.contains("permanent"))
  }

  @Test("A permanent block says permanent rather than a duration")
  func permanentBlock() throws {
    let line = BlockedClientSummary.describe(try client(expiresIn: nil), now: now)
    #expect(line.contains("permanent"))
    #expect(!line.contains("expires in"))
  }

  /// **The case the clock made untestable.** The row leaves the list when the service says
  /// the block has lapsed, but until that lands the expiry is in the past — and a negative
  /// duration formats as time ADDED rather than time left.
  @Test("A block that has just lapsed floors at zero rather than going negative")
  func lapsedBlockDoesNotGoNegative() throws {
    let lapsed = try client(expiresIn: -60)
    let remaining = BlockedClientSummary.remaining(
      until: lapsed.expiresAt!, now: now)
    #expect(!remaining.contains("-"))
    #expect(BlockedClientSummary.describe(lapsed, now: now).contains("expires in"))
  }

  @Test("Whole seconds, so no zero-second component is rendered beside a minute")
  func wholeSeconds() {
    // 4 minutes and a fraction: the fraction must not become its own component.
    let remaining = BlockedClientSummary.remaining(
      until: now.addingTimeInterval(240.7), now: now)
    #expect(!remaining.contains("."))
  }

  @Test("A repeat offender's history is named; a first offence is not")
  func offenceHistory() throws {
    #expect(
      !BlockedClientSummary.describe(try client(offenceCount: 1), now: now).contains("before"))
    #expect(
      BlockedClientSummary.describe(try client(offenceCount: 3), now: now)
        .contains("blocked 3 times before"))
  }

  /// The count and its noun agree, which is what `Int.counted` exists for: "1 failed
  /// attempt(s)" reads as unfinished copy.
  @Test("One failure is singular")
  func singularFailure() throws {
    #expect(
      BlockedClientSummary.describe(try client(failureCount: 1), now: now)
        .contains("1 failed attempt ·"))
  }

  @Test("The parts are joined in one line, in order")
  func partsAreOrdered() throws {
    let line = BlockedClientSummary.describe(try client(offenceCount: 2), now: now)
    let parts = line.components(separatedBy: " · ")
    #expect(parts.count == 4)
    #expect(parts[0] == "10 failed attempts")
    #expect(parts[1] == "auth.invalid_credential")
    #expect(parts[3] == "blocked 2 times before")
  }
}
