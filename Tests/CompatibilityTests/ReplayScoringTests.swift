//  ReplayScoringTests
//  "I could not check this" is not "these agree".
//
//  `ResponseDiff` raises `.notCompared` when one side's array is empty, so the elements were
//  never compared, and its own comment states why the kind exists: "so a replay can count
//  what it could not see instead of scoring it as a pass: the failure this whole harness
//  exists to prevent is a check that silently stops checking."
//
//  `ReplayResult.isMatch` then scored it as a pass. The predicate was
//  `differences.allSatisfy { $0.kind == .notCompared }`, which is true of an empty list AND
//  of a list made entirely of unverified entries — so the two halves of the harness disagreed
//  about the one thing it was built to get right, and the disagreement was worth six of the
//  forty-four fixtures the corpus called matching.
//
//  `FixtureReplayTests` now enforces this through the baseline ratchet: revert `isMatch`, or
//  stop raising `.notCompared` at all, and those six "start matching" and fail as stale
//  entries. That is a strong property and an indirect one — it needs the whole corpus, a
//  server and a database to state a rule about one boolean. This file states the rule.

import Foundation
import Testing

@testable import BBParity

@Suite("Replay scoring")
struct ReplayScoringTests {

  private func result(
    _ differences: [Difference], status: (expected: Int, actual: Int) = (200, 200),
    skipped: ReplayResult.SkipReason? = nil, error: String? = nil
  ) -> ReplayResult {
    ReplayResult(
      fixture: "f.json", method: "GET", path: "/api/v1/thing",
      expectedStatus: status.expected, actualStatus: status.actual,
      differences: differences, skipped: skipped, error: error)
  }

  private var unverified: Difference {
    .init(kind: .notCompared, path: "data", detail: "5 expected; empty here")
  }

  @Test("Nothing to report is a match")
  func agreementMatches() {
    #expect(result([]).isMatch)
  }

  @Test("An unverified array is NOT a match")
  func unverifiedIsNotAMatch() {
    // The bug, stated directly. Everything else in this file is the boundary around it.
    #expect(!result([unverified]).isMatch)
  }

  @Test("Unverified alongside a real difference is not a match either")
  func unverifiedWithRealDifferenceIsNotAMatch() {
    let real = Difference(kind: .valueDiffers, path: "data.id", detail: "1 vs 2")
    #expect(!result([unverified, real]).isMatch)
    #expect(!result([real]).isMatch)
  }

  @Test("Every difference kind counts against a match")
  func noKindIsFree() {
    // The property that makes the predicate readable: there is no privileged kind. The old
    // one privileged exactly one, which is how it went unnoticed — `.notCompared` is the
    // rarest kind in the corpus and the only one that means "no information".
    for kind in [
      Difference.Kind.missingKey, .unexpectedKey, .valueDiffers, .typeDiffers,
      .arrayLength, .notCompared,
    ] {
      #expect(
        !result([.init(kind: kind, path: "data", detail: "-")]).isMatch,
        "\(kind.rawValue) must not score as agreement")
    }
  }

  @Test("A skipped or errored fixture is never a match, however clean the diff")
  func absenceIsNotAgreement() {
    // Already true before this change, and pinned here because it is the same confusion in
    // a different place: a fixture that was not compared has not agreed with anything.
    #expect(!result([], skipped: .selfRecorded).isMatch)
    #expect(!result([], error: "connection refused").isMatch)
  }

  @Test("A status difference is not a match even with an empty diff")
  func statusStillCounts() {
    #expect(!result([], status: (200, 404)).isMatch)
  }
}
