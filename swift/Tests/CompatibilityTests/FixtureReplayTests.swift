//  FixtureReplayTests
//  The corpus, replayed. This is the test `CompatibilityContractTests` said it was.
//
//  Its header opened with "Replays fixtures recorded from the running Node server against the
//  Swift server" and nothing in the suite did: one test counted the files, one scanned them
//  for personal data, and one unit-tested the diff against hand-built dictionaries. No test
//  fed a recorded request into this server. So "the compatibility contract is mechanically
//  enforced" meant "it was enforced once, by hand, on one Mac, in August".
//
//  What this can and cannot assert
//  -------------------------------
//  The fixtures were recorded against a real Mac holding real conversations. This runs
//  against a synthetic `chat.db` with three chats in it, so no count, GUID, address or body
//  text can agree — and comparing them would bury the findings under a wall of noise.
//
//  So the comparison is `.shape`: which keys exist, what type each one is, and the literal
//  strings that ARE the contract (`status`, `message`, `error.type`). That is the whole of
//  what a client parses before it looks at anyone's data, and every divergence found so far
//  has lived in it — the envelope's `message` and `error.message` being the wrong way round
//  on every error response, `POST /contact` answering with an object where the reference
//  answers with an array, three routes adding a `data` key the reference does not send.
//
//  Value-level parity needs two servers over one database, which is `bb-parity` and a Mac.
//  This is what can run on every commit, and running on every commit is the property that
//  was missing.
//
//  The baseline
//  ------------
//  Some fixtures cannot match here and are not bugs: the recorded chat does not exist in the
//  synthetic database, the helper is not connected, the reference reached iCloud. Those are
//  listed in `Fixtures/replay-baseline.json` with a reason each, and the list is a RATCHET —
//  a fixture that starts matching must be removed from it, or this suite fails. A baseline
//  that only ever grows is a suppression list; one that cannot grow silently is a to-do list.

import BBParity
import Foundation
import Testing

@Suite("Fixture replay", .serialized)
struct FixtureReplayTests {

  @Test("The recorded corpus replays against this server")
  func replayCorpus() async throws {
    let results = try await Self.replay()
    let baseline = try Self.baseline()

    let compared = results.filter { $0.skipped == nil && $0.error == nil }
    let failing = compared.filter { !$0.isMatch }

    // A fixture that is failing and is not accounted for. This is the regression case, and
    // the report is printed in full because a name alone is not enough to act on.
    let unexpected = failing.filter { baseline[$0.fixture] == nil }
    #expect(
      unexpected.isEmpty,
      """
      \(unexpected.count) fixture(s) diverge from the reference and are not in the baseline.

      \(results.report())
      """
    )

    // A fixture that is passing and is still listed. Left alone, the baseline becomes a
    // suppression list nobody prunes — which is how a corpus stops being a contract.
    let stale = compared.filter { $0.isMatch && baseline[$0.fixture] != nil }
    let names = stale.map(\.fixture).sorted().joined(separator: ", ")
    #expect(
      stale.isEmpty,
      "these now match and must be removed from replay-baseline.json: \(names)"
    )
  }

  /// Nothing in the baseline may be a fixture that no longer exists.
  ///
  /// A stale entry silences a fixture that was renamed or re-recorded, and it does it
  /// invisibly — the suppression outlives the thing it was suppressing.
  @Test("Every baseline entry names a fixture that exists")
  func baselineHasNoGhosts() throws {
    let names = Set(
      try RecordedFixture.loadAll(from: FixtureCorpusTests.corpusRoot).map(\.name)
    )
    let ghosts = try Self.baseline().keys.filter { !names.contains($0) }.sorted()
    #expect(ghosts.isEmpty, "baselined fixtures that no longer exist: \(ghosts)")
  }

  // MARK: - Harness

  private static func replay() async throws -> [ReplayResult] {
    let fixtures = try RecordedFixture.loadAll(from: FixtureCorpusTests.corpusRoot)
    let server = try await ReplayServer.start()
    defer { Task { await server.stop() } }

    let replay = FixtureReplay(
      baseURL: server.baseURL, password: server.password, mode: .shape
    )
    return await replay.run(fixtures.filter(\.isV1))
  }

  /// Fixture name to the reason it cannot match here.
  static func baseline() throws -> [String: String] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/replay-baseline.json")
    let data = try Data(contentsOf: url)
    guard
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = root["entries"] as? [String: String]
    else {
      throw CocoaError(.propertyListReadCorrupt)
    }
    return entries
  }
}

/// Which of the reference's v1 routes the corpus can actually hold to account.
///
/// A recorded fixture is only a contract if the REFERENCE recorded it. Fifteen of the
/// reference's ninety-eight v1 routes have no fixture except one this server produced —
/// diffing those compares the candidate against a photograph of the candidate, which cannot
/// fail and proves nothing. Nothing in the suite could see that, because nothing decoded a
/// fixture: `FixtureCorpusTests` counts files and greps them for email addresses.
///
/// The recording source is inferred from the CORS header, which is the only fingerprint in
/// the file — see `RecordedFixture.recordedFrom`. The recorder does not stamp its source, and
/// it should; that is in TODO.md.
@Suite("Corpus provenance")
struct CorpusProvenanceTests {

  /// v2 is ours, so a v2 fixture recorded from this server is correct and expected. This is
  /// only about v1, where a reference exists to be recorded.
  @Test("The self-recorded v1 fixtures are the known set, and it does not grow")
  func selfRecordedV1IsPinned() throws {
    let fixtures = try RecordedFixture.loadAll(from: FixtureCorpusTests.corpusRoot)
    let selfRecorded = Set(
      fixtures.filter { $0.isV1 && $0.recordedFrom == .swift }.map(\.name)
    )

    let added = selfRecorded.subtracting(Self.knownSelfRecorded).sorted()
    #expect(
      added.isEmpty,
      """
      These v1 fixtures were recorded from THIS server, not the reference, so they pin \
      nothing. Re-record them against a Node server, or add them here with a reason: \
      \(added)
      """
    )

    let cleared = Self.knownSelfRecorded.subtracting(selfRecorded).sorted()
    #expect(cleared.isEmpty, "re-recorded against the reference; remove from the list: \(cleared)")
  }

  /// The fifteen routes whose only reference is this server, as of the audit that found them.
  ///
  /// Every one is a Private-API-backed write — group management, leave, participants, the
  /// group icon, the FaceTime session routes, the alias change — which is exactly the surface
  /// a recording run against a real Mac is most reluctant to exercise, and exactly the
  /// surface where the helper work is happening. They need a throwaway conversation and a
  /// deliberate recording session. See TODO.md.
  static let knownSelfRecorded: Set<String> = [
    "delete_api_v1_chat_any;+;621276cd60bf47129edc6273b6bf76c2-5baa61-200.json",
    "delete_api_v1_chat_any;+;bcb9a1843dfc4b65bb47ce50afec8d32_:id-5baa61-200.json",
    "delete_api_v1_chat_any;+;bcb9a1843dfc4b65bb47ce50afec8d32_icon-5baa61-200.json",
    "delete_api_v1_chat_any;+;bcb9a1843dfc4b65bb47ce50afec8d32_participant-5baa61-200.json",
    "delete_api_v1_webhook_:id-5baa61-200.json",
    "get_api_v1_chat_any;-;person@example.com-5baa61-200.json",
    "get_api_v1_chat_any;-;person@example.com_message-b7cb7c-200.json",
    "get_api_v1_contact-5baa61-200.json",
    "get_api_v1_fcm_client-5baa61-200.json",
    "get_api_v1_handle_person@example.com_focus-5baa61-200.json",
    "post_api_v1_chat_any;+;621276cd60bf47129edc6273b6bf76c2_leave-5baa61-500.json",
    "post_api_v1_chat_any;+;bcb9a1843dfc4b65bb47ce50afec8d32_icon-5baa61-200.json",
    "post_api_v1_chat_any;+;bcb9a1843dfc4b65bb47ce50afec8d32_leave-5baa61-200.json",
    "post_api_v1_chat_any;+;bcb9a1843dfc4b65bb47ce50afec8d32_participant-5baa61-200.json",
    "post_api_v1_chat_any;+;bcb9a1843dfc4b65bb47ce50afec8d32_participant_add-5baa61-200.json",
    "post_api_v1_chat_any;+;bcb9a1843dfc4b65bb47ce50afec8d32_participant_add-5baa61-500.json",
    "post_api_v1_chat_any;+;bcb9a1843dfc4b65bb47ce50afec8d32_participant_remove-5baa61-200.json",
    "post_api_v1_facetime_answer_:id-5baa61-500.json",
    "post_api_v1_facetime_leave_:id-5baa61-201.json",
    "post_api_v1_facetime_session-5baa61-200.json",
    "post_api_v1_icloud_account_alias-5baa61-200.json",
    "post_api_v1_icloud_account_alias-5baa61-400.json",
    "post_api_v1_webhook-5baa61-200.json",
  ]
}
