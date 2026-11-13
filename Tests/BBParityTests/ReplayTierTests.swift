//  ReplayTierTests
//  The ladder decides what a test suite is allowed to do to the machine it runs on, so it is
//  asserted rather than read.
//
//  The failure this guards against is not subtle and has happened: the first run of the
//  replay harness locked this developer's Mac over a remote session. The guard is a
//  classification derived from the route table, and two properties of it are asserted here
//  because each would fail silently: it FAILS CLOSED (a route nothing classified is `.never`,
//  not the floor), and the deny-list outranks whatever classification it is handed.

import Foundation
import Testing

@testable import BBParity

@Suite("Replay tiers")
struct ReplayTierTests {

  private func fixture(_ method: String, _ path: String) -> RecordedFixture {
    RecordedFixture(
      name: "\(method.lowercased())_\(path).json",
      request: .init(
        method: method, path: path, headers: [:], body: .empty
      ),
      response: .init(status: 200, headers: [:], body: .empty)
    )
  }

  /// A classification in the shape the real suite derives from `RouteCatalog`. A handful of
  /// real entries, so the lookup is exercised against the shapes it actually meets.
  private let routes = RouteReach([
    "GET /api/v1/chat/count": .harness,
    "GET /api/v1/message/count": .harness,
    "GET /api/v1/message/:guid": .harness,
    "POST /api/v1/message/query": .harness,
    "POST /api/v1/webhook": .harness,
    "POST /api/v1/chat/:guid/read": .privateAPIDouble,
    "POST /api/v1/chat/:guid/typing": .privateAPIDouble,
    "DELETE /api/v1/chat/:guid/typing": .privateAPIDouble,
    "DELETE /api/v1/chat/:guid/:messageGuid": .privateAPIDouble,
    "POST /api/v1/message/text": .realMac,
    "POST /api/v1/chat/new": .realMac,
    // Deliberately WRONG, to prove the deny-list outranks any classification it is handed.
    "POST /api/v1/mac/lock": .harness,
    "GET /api/v1/server/restart/soft": .harness,
  ])

  // MARK: The ladder

  @Test("A route takes the tier its classification gives it")
  func classifiedRoutesTakeTheirTier() {
    #expect(
      FixtureReplay.tier(for: fixture("GET", "/api/v1/chat/count"), routes: routes) == .harness)
    #expect(
      FixtureReplay.tier(for: fixture("POST", "/api/v1/message/query"), routes: routes) == .harness)
    let read = fixture("POST", "/api/v1/chat/any;-;person@example.com/read")
    #expect(FixtureReplay.tier(for: read, routes: routes) == .privateAPIDouble)
    #expect(
      FixtureReplay.tier(for: fixture("POST", "/api/v1/message/text"), routes: routes) == .realMac)
  }

  /// **The one that matters.** A route nothing classified is not a route anything has
  /// vouched for, so it is the top of the ladder, never the bottom.
  @Test("An unclassified route is the most restrictive tier")
  func unclassifiedRoutesFailClosed() {
    // Not in the classification at all, under a version, a group and a verb that are.
    for (method, path) in [
      ("POST", "/api/v2/icloud/findmy/friend/request"),
      ("POST", "/api/v2/sticker"),
      ("POST", "/api/v1/handle/somewhere-new"),
      ("PUT", "/api/v1/chat/count"),
      ("GET", "/api/v1/not/a/route"),
    ] {
      #expect(
        FixtureReplay.tier(for: fixture(method, path), routes: routes) == .never,
        "\(method) \(path) is unclassified and must not be replayable")
    }
    #expect(ReplayTier.allCases.max() == .never)
  }

  @Test("With no classification, nothing is replayable")
  func emptyClassificationReplaysNothing() {
    let none = RouteReach([:])
    #expect(FixtureReplay.tier(for: fixture("GET", "/api/v1/ping"), routes: none) == .never)
    #expect(FixtureReplay.isDestructive(fixture("GET", "/api/v1/ping"), routes: none))
  }

  @Test("An unclassified fixture is reported as unclassified, not as acting on this Mac")
  func unclassifiedSkipReason() async {
    // Refused before any request is built, so the address is never dialled.
    let replay = FixtureReplay(baseURL: "http://127.0.0.1:9", password: "unused", routes: routes)
    #expect(await replay.replay(fixture("GET", "/api/v1/not/a/route")).skipped == .unclassified)
    #expect(await replay.replay(fixture("POST", "/api/v1/mac/lock")).skipped == .destructive)
    #expect(await replay.replay(fixture("POST", "/api/v1/message/text")).skipped == .destructive)
    let read = fixture("POST", "/api/v1/chat/any;-;person@example.com/read")
    #expect(await replay.replay(read).skipped == .aboveTier)
  }

  @Test("A route matching several templates takes the most restrictive")
  func overlappingTemplatesTakeTheHighest() {
    let overlapping = RouteReach([
      "DELETE /api/v1/chat/:guid/typing": .harness,
      "DELETE /api/v1/chat/:guid/:messageGuid": .privateAPIDouble,
    ])
    let typing = fixture("DELETE", "/api/v1/chat/any;-;person@example.com/typing")
    #expect(FixtureReplay.tier(for: typing, routes: overlapping) == .privateAPIDouble)
  }

  @Test("The deny-list is the floor and no classification admits it")
  func denyListedRoutesAreNever() {
    // `routes` above classifies two of these as `.harness`, on purpose.
    #expect(FixtureReplay.tier(for: fixture("POST", "/api/v1/mac/lock"), routes: routes) == .never)
    #expect(
      FixtureReplay.tier(for: fixture("GET", "/api/v1/server/restart/soft"), routes: routes)
        == .never)
    for route in FixtureReplay.destructiveRoutes {
      let parts = route.split(separator: " ", maxSplits: 1).map(String.init)
      let harnessEverything = RouteReach([route: .harness])
      #expect(
        FixtureReplay.tier(for: fixture(parts[0], parts[1]), routes: harnessEverything) == .never,
        "\(route) escaped the deny-list")
    }
  }

  // MARK: The safety property two other suites rest on

  @Test("isDestructive answers the default-tier question")
  func isDestructiveIsTheDefaultTier() {
    // What `ReplayDenyListTests` and `DenyListedShapeCoverageTests` assert against.
    #expect(FixtureReplay.isDestructive(fixture("POST", "/api/v1/mac/lock"), routes: routes))
    #expect(FixtureReplay.isDestructive(fixture("POST", "/api/v1/message/text"), routes: routes))
    let read = fixture("POST", "/api/v1/chat/any;-;person@example.com/read")
    #expect(FixtureReplay.isDestructive(read, routes: routes))
    #expect(!FixtureReplay.isDestructive(fixture("POST", "/api/v1/message/query"), routes: routes))
    #expect(!FixtureReplay.isDestructive(fixture("GET", "/api/v1/message/count"), routes: routes))
  }

  // MARK: The matcher

  @Test("A template matches an instance segment for segment")
  func templateMatching() {
    #expect(
      FixtureReplay.matches(
        template: "POST /api/v1/chat/:guid/read",
        route: "POST /api/v1/chat/any;-;person@example.com/read"))
    // A chat GUID carries `;` and `+`, which is why this is segment-wise rather than a
    // substring or a regular expression.
    #expect(
      FixtureReplay.matches(
        template: "POST /api/v1/chat/:guid/read",
        route: "POST /api/v1/chat/any;+;chat000000000000000001/read"))
  }

  @Test("A longer path is not an instance of a shorter template")
  func templateRejectsExtraSegments() {
    // The case a substring test gets wrong, and it is a tier boundary: these are two
    // different routes and a naive match would hand one the other's classification.
    #expect(
      !FixtureReplay.matches(
        template: "POST /api/v1/chat/:guid/participant",
        route: "POST /api/v1/chat/any;+;x/participant/add"))
  }

  @Test("The verb is part of the identity")
  func templateRejectsWrongVerb() {
    #expect(
      !FixtureReplay.matches(
        template: "POST /api/v1/chat/:guid/typing",
        route: "DELETE /api/v1/chat/any;-;person@example.com/typing"))
  }

  // MARK: Reading the environment

  @Test("No variable means the tier that was always replayed")
  func defaultIsHarness() {
    #expect(ReplayTier.requested(from: [:]) == .ceiling(.harness))
    #expect(ReplayTier.requested(from: ["BB_PARITY_TIER": ""]) == .ceiling(.harness))
  }

  @Test("The stub tier is spelled `stub` and is admitted")
  func stubIsAdmitted() {
    #expect(ReplayTier.requested(from: ["BB_PARITY_TIER": "stub"]) == .ceiling(.privateAPIDouble))
    #expect(ReplayTier.requested(from: ["BB_PARITY_TIER": " STUB "]) == .ceiling(.privateAPIDouble))
  }

  @Test("A tier that is named but not built is refused, not ignored")
  func unbuiltTiersAreRefused() {
    // Refused rather than falling back, because a run that quietly dropped to the default
    // would report a pass over a tier it never touched.
    let live = ReplayTier.requested(from: ["BB_PARITY_TIER": "live"])
    #expect(live == .notBuilt(.realMac))
    #expect(live.ceiling == nil)
    #expect(live.refusal?.contains("is not built") == true)
    #expect(ReplayTier.requested(from: ["BB_PARITY_TIER": "never"]) == .notBuilt(.never))
  }

  @Test("An unrecognised value is refused and names what is supported")
  func unrecognisedValuesAreRefused() {
    let nonsense = ReplayTier.requested(from: ["BB_PARITY_TIER": "yes-please"])
    #expect(nonsense == .unrecognised("yes-please"))
    #expect(nonsense.ceiling == nil)
    #expect(nonsense.refusal?.contains("harness") == true)
    #expect(nonsense.refusal?.contains("stub") == true)
  }
}
