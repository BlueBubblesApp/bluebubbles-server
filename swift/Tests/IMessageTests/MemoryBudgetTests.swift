//  MemoryBudgetTests
//  § 10's budget, asserted rather than aspired to.
//
//  § 10 makes memory a design constraint with numbers, and § 19 says CI asserts them. Nothing
//  did — so the budget was a table in a document, every tactic listed under it was unverified,
//  and "flat memory curve" had no definition anything could fail on. That matters more here
//  than in most projects: the stated target is an OLD MAC MINI, and the two named regressions
//  in the git history (`fix: potential memory leak with poller`, `fix: improved cache pruning`)
//  are exactly what a budget test exists to stop recurring.
//
//  What these DO assert is growth across a workload — the query budget and the return to
//  baseline. What they deliberately do NOT assert is absolute idle footprint, because a test
//  runner hosts XCTest, the Testing library and the whole package's symbols, so "idle" here is
//  nothing like the idle of a shipped headless server. Measuring it would produce a number
//  that fails for reasons unrelated to the server. § 10's < 60 MB idle target needs the real
//  binary, and that belongs in the soak test, not here.
//
//  See `.claude/docs/performance.md` and `.claude/docs/workflow.md`.

import BBCore
import Foundation
import Testing

@testable import BBIMessage

@Suite("Memory budget", .serialized)
struct MemoryBudgetTests {

  /// § 10: "Serving a 1000-message query — no more than +40 MB over idle".
  static let queryBudgetBytes: Int64 = 40 * 1_048_576

  /// Measured as a delta over a warmed baseline, never as an absolute.
  ///
  /// The first query through a fresh repository pays for things that are not the query:
  /// GRDB's statement cache, the schema probe, and every lazily-initialised singleton the
  /// first row touches. Charging those to the budget would make the test a measure of
  /// start-up cost that happens to run a query.
  private func warmed(_ fixture: ChatDatabaseFixture) async throws {
    var query = MessageRepository.MessageQuery()
    query.limit = 50
    _ = try await fixture.repository.messages(query)
    autoreleasepool {}
  }

  @Test("A 1000-message query stays inside the query budget")
  func thousandMessageQueryBudget() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    // A thousand real rows, which is the cap `MessageQuery` enforces and therefore the
    // largest single read a client can ask for.
    let base = Date().addingTimeInterval(-100_000)
    for index in 0..<1000 {
      _ = try await fixture.insertMessage(
        guid: "MEM-\(index)",
        text: "message \(index) with enough text to be a realistic row rather than a token",
        at: base.addingTimeInterval(Double(index))
      )
    }

    try await warmed(fixture)

    var query = MessageRepository.MessageQuery()
    query.limit = 1000
    let (rows, grewBy) = await MemoryFootprint.growth {
      (try? await fixture.repository.messages(query)) ?? []
    }

    #expect(rows.count == 1000, "the fixture should have produced a full page")
    #expect(
      grewBy < Self.queryBudgetBytes,
      "a 1000-message query grew the footprint by \(grewBy / 1_048_576) MB; § 10 budgets 40 MB"
    )
  }

  @Test("Repeated queries return to baseline rather than accumulating")
  func repeatedQueriesDoNotAccumulate() async throws {
    // The property that actually matters, and the one the poller regressions violated.
    // A single query inside budget proves nothing about a server that runs for weeks:
    // what breaks is per-query residue that never comes back, and it only shows up when
    // the same work is repeated.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let base = Date().addingTimeInterval(-100_000)
    for index in 0..<500 {
      _ = try await fixture.insertMessage(
        guid: "LOOP-\(index)",
        text: "message \(index)",
        at: base.addingTimeInterval(Double(index))
      )
    }

    try await warmed(fixture)

    var query = MessageRepository.MessageQuery()
    query.limit = 500

    let before = try #require(MemoryFootprint.current(), "no memory reading available")
    for _ in 0..<20 {
      _ = try await fixture.repository.messages(query)
    }
    autoreleasepool {}
    let after = try #require(MemoryFootprint.current())

    // Twenty passes over the same rows. Anything retained per call compounds twentyfold
    // here, which is what makes a leak visible at this scale rather than at production
    // scale weeks later. The allowance is generous on purpose — this is a leak detector,
    // not a high-water mark, and a tight bound would be flaky for no gain.
    let grewBy = Int64(after) - Int64(before)
    #expect(
      grewBy < Self.queryBudgetBytes,
      "20 identical queries grew the footprint by \(grewBy / 1_048_576) MB, suggesting per-query memory is retained"
    )
  }

  @Test("The measurement itself reports a plausible number")
  func measurementIsSane() throws {
    // Guards the guard. `phys_footprint` returning 0 — or the call failing and being
    // treated as 0 — would make every budget assertion above pass unconditionally, which
    // is the one way a memory test can be worse than no memory test.
    let footprint = try #require(MemoryFootprint.current(), "task_info refused to answer")
    #expect(footprint > 1_048_576, "a running test process cannot be using under 1 MB")
    #expect(
      footprint < 8_589_934_592,
      "8 GB in a test process means the wrong field is being read"
    )
  }
}
