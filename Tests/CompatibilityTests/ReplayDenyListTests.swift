//  ReplayDenyListTests
//  The fixture replay is not allowed to act on the machine it runs on.
//
//  Not a tidiness rule. The first run of the harness LOCKED this developer's Mac and
//  restarted Messages, on a machine being used over a remote session: the corpus contains
//  recordings of `mac/lock` and `mac/imessage/restart`, and replaying a recording means
//  making the call again for real. `FixtureReplay.destructiveRoutes` is the guard; this file
//  is the assertion that the guard still covers the routes it was written for, checked
//  against the corpus as it actually is rather than against the list's own contents.
//
//  Both directions matter. Nothing that sends may replay, and note that "the helper is not
//  connected" is NOT what makes that safe, since the AppleScript backend needs no helper and
//  will happily message a real person. But the read-only POSTs (`message/query`,
//  `chat/query`) must still replay, because a deny-list broad enough to be safe and broad
//  enough to be useless is easy to write by accident and looks identical in CI.
//
//  → `docs/TESTING.md` § "The parity harness".

import BBParity
import Foundation
import Testing

@Suite("Replay deny-list")
struct ReplayDenyListTests {

  /// The harness locked this developer's Mac on its first run. Asserted, not assumed.
  @Test("No fixture that acts on the machine is ever replayed")
  func destructiveFixturesAreRefused() throws {
    let fixtures = try RecordedFixture.loadAll(from: FixtureCorpusTests.corpusRoot)
    let replayable = fixtures.filter { !FixtureReplay.isDestructive($0) }
      .map { "\($0.request.method) \($0.request.routePath)" }

    for route in ["POST /api/v1/mac/lock", "POST /api/v1/mac/imessage/restart"] {
      #expect(!replayable.contains(route), "\(route) would be replayed for real")
    }
    // Nothing that sends, either: the AppleScript backend needs no helper, so "the
    // helper is not connected" is not what makes this safe.
    #expect(!replayable.contains { $0.hasPrefix("POST /api/v1/message/text") })
    #expect(!replayable.contains { $0.hasPrefix("POST /api/v1/message/attachment") })
    #expect(!replayable.contains { $0.hasPrefix("POST /api/v1/message/multipart") })
    #expect(!replayable.contains { $0.hasPrefix("POST /api/v1/message/react") })

    // And the read-only POSTs survive it, because a deny-list broad enough to be safe and
    // broad enough to be useless is easy to write by accident.
    #expect(replayable.contains("POST /api/v1/message/query"))
    #expect(replayable.contains("POST /api/v1/chat/query"))
  }
}
