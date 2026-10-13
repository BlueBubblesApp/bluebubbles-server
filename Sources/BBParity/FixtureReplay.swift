//  FixtureReplay
//  Issues a recorded request against a running server and diffs the answer.
//
//  ONE caller: `Tests/CompatibilityTests/FixtureReplayTests`, which mounts the real router
//  in-process over a synthetic `chat.db` and runs the whole corpus on every CI build. It
//  compares SHAPE, because the fixtures were recorded against a real Mac's messages and this
//  one has seven.
//
//  This header used to open with "Two callers, deliberately" and name
//  `bb-parity replay --candidate …` as the second, reading the corpus against a server with
//  real data so the comparison could be strict. **There is no such subcommand and never was.**
//  `bb-parity` takes `--reference` and `--candidate` and asks two LIVE servers the same
//  questions through `SideBySideRunner`; it reads no fixtures and does not touch this type.
//  The claim was load-bearing enough to be copied into CONTRIBUTING.md before anyone opened
//  `Sources/ParityTool` to check, which is rule 8 in the root CLAUDE.md doing exactly what it
//  warns about.
//
//  The `mode` parameter is still real and still worth having: `.strict` is what
//  `SideBySideRunner` gets from `ResponseDiff.compare`'s own default, and a future caller
//  holding one database could pass it here.

import Foundation

/// What one replayed fixture produced.
public struct ReplayResult: Sendable {
  public let fixture: String
  public let method: String
  public let path: String
  public let expectedStatus: Int
  public let actualStatus: Int
  public let differences: [Difference]
  /// Why this fixture was not compared at all, if it was not.
  public let skipped: SkipReason?
  public let error: String?

  public enum SkipReason: String, Sendable {
    /// The fixture's own reference is this server. Replaying it compares the candidate
    /// with a photograph of the candidate, which cannot fail and proves nothing.
    case selfRecorded = "recorded from this server, not the reference"
    /// The recorder stored a digest instead of the bytes.
    case binaryBody = "binary response body"
    /// The recorder round-tripped a multipart body through UTF-8, which is lossy.
    case lossyRequestBody = "multipart body was not recorded byte-exactly"
    /// Not JSON on one side or the other, so there is no object to diff.
    case nonJSONBody = "response is not JSON"
    /// The route does something to the machine, and a replay would do it for real.
    case destructive = "the route acts on this Mac and is never replayed"
    /// The route reaches only the Private API double, and this run did not ask for that
    /// tier. Distinct from `.destructive` because it is a SETTING, not a refusal: the
    /// fixture is replayable and simply was not asked for. Reporting both as "destructive"
    /// would make a run that could have covered sixty more routes look as though it had
    /// been protected from them.
    case aboveTier = "above the tier this run was asked for (see BB_PARITY_TIER)"
    /// No route in the table serves the path, so nothing has said how far it reaches and it
    /// is held at `.never`. Distinct from `.destructive` so the count of routes that act on
    /// this Mac stays a count of exactly those.
    case unclassified = "no route in the table serves it, so nothing has classified it"
  }

  /// Whether the two agree. A skipped fixture is not a match: it is an absence of one.
  ///
  /// **`.notCompared` is not a match either**, and this used to say it was:
  /// `differences.allSatisfy { $0.kind == .notCompared }` is true of an empty list AND of a
  /// list made entirely of "I could not check this". `ResponseDiff` raises that kind
  /// precisely so a replay can count what it could not see instead of scoring it as a pass —
  /// its own comment says the failure this harness exists to prevent is a check that
  /// silently stops checking — and then the scorer counted it as a pass.
  ///
  /// It was not theoretical: six of the forty-four fixtures the corpus called matching were
  /// matching only on unverified arrays, `data.properties` and a whole `data` among them.
  /// Those are now failures with a baseline entry each, which is the difference between a
  /// gap you can read and a gap that reads as a pass.
  public var isMatch: Bool {
    skipped == nil && error == nil && expectedStatus == actualStatus && differences.isEmpty
  }
}

public struct FixtureReplay: Sendable {

  private let baseURL: String
  private let password: String
  private let mode: DiffMode
  private let session: URLSession
  /// The highest tier this run will replay. See `ReplayTier`.
  public let ceiling: ReplayTier
  /// How far every route in the table reaches. See `RouteReach`.
  ///
  /// INJECTED rather than built here, because the authority is `RouteTable`'s own metadata
  /// and `BBParity` has no dependencies on purpose: the caller derives it and hands it over.
  /// REQUIRED rather than defaulted, because the only default there is ("nothing is known")
  /// classifies every route `.never` and replays nothing.
  public let routes: RouteReach

  /// - Parameter mode: `.shape` when the server under test holds different data from the
  ///   one the corpus was recorded against, which is every in-process run.
  /// - Parameter ceiling: how far this run may reach. Defaults to `.harness`, which is what
  ///   was replayed before tiers existed.
  public init(
    baseURL: String, password: String, mode: DiffMode = .shape,
    ceiling: ReplayTier = .harness, routes: RouteReach
  ) {
    self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    self.password = password
    self.mode = mode
    self.ceiling = ceiling
    self.routes = routes

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    self.session = URLSession(configuration: configuration)
  }

  public func run(_ fixtures: [RecordedFixture]) async -> [ReplayResult] {
    var results: [ReplayResult] = []
    // Sequential. Several of these fixtures write to the server's own database (a
    // webhook, a theme, a scheduled message) and running them concurrently would let one
    // fixture's write land inside another's read.
    for fixture in fixtures {
      results.append(await replay(fixture))
    }
    return results
  }

  public func replay(_ fixture: RecordedFixture) async -> ReplayResult {
    if let reason = skipReason(for: fixture) {
      return ReplayResult(
        fixture: fixture.name, method: fixture.request.method,
        path: fixture.request.routePath,
        expectedStatus: fixture.response.status, actualStatus: 0,
        differences: [], skipped: reason, error: nil
      )
    }

    do {
      let (status, object, raw) = try await send(fixture)

      guard let expected = fixture.response.body.jsonObject else {
        return ReplayResult(
          fixture: fixture.name, method: fixture.request.method,
          path: fixture.request.routePath,
          expectedStatus: fixture.response.status, actualStatus: status,
          differences: [], skipped: .nonJSONBody, error: nil
        )
      }
      guard let actual = object else {
        return ReplayResult(
          fixture: fixture.name, method: fixture.request.method,
          path: fixture.request.routePath,
          expectedStatus: fixture.response.status, actualStatus: status,
          differences: [
            .init(kind: .typeDiffers, path: "<body>", detail: "object vs \(raw.prefix(80))")
          ],
          skipped: nil, error: nil
        )
      }

      return ReplayResult(
        fixture: fixture.name, method: fixture.request.method,
        path: fixture.request.routePath,
        expectedStatus: fixture.response.status, actualStatus: status,
        differences: ResponseDiff.compare(expected: expected, actual: actual, mode: mode),
        skipped: nil, error: nil
      )
    } catch {
      return ReplayResult(
        fixture: fixture.name, method: fixture.request.method,
        path: fixture.request.routePath,
        expectedStatus: fixture.response.status, actualStatus: 0,
        differences: [], skipped: nil, error: String(describing: error)
      )
    }
  }

  private func skipReason(for fixture: RecordedFixture) -> ReplayResult.SkipReason? {
    // The tier the fixture NEEDS against the tier this run allows. `.harness` is the
    // default; see `ReplayTier`.
    let needed = Self.tier(for: fixture, routes: routes)
    if needed > ceiling {
      let route = "\(fixture.request.method) \(fixture.request.routePath)"
      if needed == .privateAPIDouble { return .aboveTier }
      if !Self.destructiveRoutes.contains(route) && !routes.classifies(route) {
        return .unclassified
      }
      return .destructive
    }
    if fixture.recordedFrom == .swift { return .selfRecorded }
    if case .binary = fixture.response.body { return .binaryBody }
    // A multipart upload's body was stored as UTF-8 text, which replaced every non-UTF-8
    // byte of the embedded PNG with U+FFFD. Re-encoding that and calling it the same
    // request would test the harness's corruption, not the server.
    if case .text = fixture.request.body { return .lossyRequestBody }
    return nil
  }

  private func send(
    _ fixture: RecordedFixture
  ) async throws -> (status: Int, json: [String: Any]?, raw: String) {
    let (status, data) = try await ParityRequest(fixture).send(
      to: baseURL, password: password, session: session)
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return (status, object, String(decoding: data, as: UTF8.self))
  }

  /// Routes that act on the machine, refused before the request is built.
  ///
  /// **This is not a nicety.** The first run of this harness locked the developer's Mac:
  /// `POST /mac/lock` was in the corpus, the handler is real, and a replay is a request like
  /// any other. It went on to restart Messages and kick off a service restart in the same
  /// pass, on a machine that was being used over a remote session at the time.
  ///
  /// A deny-list rather than a "test mode" flag on the handlers, for two reasons: the flag
  /// would be one more thing a future harness could forget to set, and the handlers are
  /// exactly what this is here to exercise faithfully. Refusing at the driver keeps the
  /// server honest and the driver safe.
  ///
  /// Matched on the route, not on the fixture name, so a re-recording with a different
  /// filename is still refused.
  public static let destructiveRoutes: Set<String> = [
    // Locks the screen. Nothing recovers from this without the operator's password.
    "POST /api/v1/mac/lock",
    // Quits and relaunches Messages.app, dropping whatever the operator was doing in it.
    "POST /api/v1/mac/imessage/restart",
    // The same for FaceTime.app (`ApplicationRestartCoordinator`).
    "POST /api/v2/facetime/restart",
    // Tears down every service, or the whole process, under the test that is driving it.
    "GET /api/v1/server/restart/soft",
    "GET /api/v1/server/restart/hard",
    // Downloads and installs a new build of the server.
    "POST /api/v1/server/update/install",
  ]

  /// How far this fixture reaches, and therefore the tier it needs to be admitted.
  ///
  /// The deny-list first, whatever `routes` says, so no classification can lift a route off
  /// the floor. Then the route table's own answer through `RouteReach`, which is `.never` for
  /// a path the table does not serve: the classification FAILS CLOSED. A route is replayed
  /// only because something positively placed it on a lower rung, never because it is
  /// missing from a list of dangerous ones.
  public static func tier(for fixture: RecordedFixture, routes: RouteReach) -> ReplayTier {
    let route = "\(fixture.request.method) \(fixture.request.routePath)"
    // The floor. Nothing moves these, and nothing should be able to.
    if destructiveRoutes.contains(route) { return .never }
    return routes.tier(of: route)
  }

  /// Whether a concrete `"POST /api/v1/chat/any;-;x@example.com/read"` is an instance of a
  /// template `"POST /api/v1/chat/:guid/read"`.
  ///
  /// Segment-wise, because a chat GUID contains `;` and `+` and, on the group routes, a
  /// second GUID-shaped segment after it. A substring test would match
  /// `/chat/:guid/participant` against `/chat/:guid/participant/add`, which are different
  /// routes with different tiers.
  static func matches(template: String, route: String) -> Bool {
    let left = template.split(separator: " ", maxSplits: 1)
    let right = route.split(separator: " ", maxSplits: 1)
    guard left.count == 2, right.count == 2, left[0] == right[0] else { return false }
    let templateSegments = left[1].split(separator: "/", omittingEmptySubsequences: false)
    let routeSegments = right[1].split(separator: "/", omittingEmptySubsequences: false)
    guard templateSegments.count == routeSegments.count else { return false }
    for (templateSegment, routeSegment) in zip(templateSegments, routeSegments) {
      if templateSegment.hasPrefix(":") { continue }
      if templateSegment != routeSegment { return false }
    }
    return true
  }

  /// Whether this fixture is withheld from a DEFAULT run.
  ///
  /// The corpus is documented as read-only and mostly is, but the send fixtures were
  /// recorded and committed, and "the helper is not connected so it will fail anyway" is an
  /// assumption about the machine the test runs on, not a property of the test. The
  /// AppleScript backend needs no helper.
  ///
  /// Kept as the DEFAULT-TIER question rather than being replaced by `tier(for:routes:)`,
  /// and the distinction matters: `ReplayDenyListTests` and `DenyListedShapeCoverageTests`
  /// assert against this, and what they are really asserting is "not replayed unless
  /// somebody asks for it". A fixture that only reaches the Private API double is withheld
  /// here, because the default ceiling is `.harness`, and is admitted by
  /// `BB_PARITY_TIER=stub`, which is a deliberate act.
  public static func isDestructive(_ fixture: RecordedFixture, routes: RouteReach) -> Bool {
    tier(for: fixture, routes: routes) > .harness
  }
}

/// How far each route the server mounts can reach, keyed by its template:
/// `"POST /api/v1/chat/:guid/read"` to `.privateAPIDouble`.
///
/// Built by the caller from `RouteTable`, because that is where the facts live (the method,
/// the Private API gate, the handler) and `BBParity` has no dependencies. See
/// `ReplayTierSelection` in the compatibility suite.
public struct RouteReach: Sendable {

  /// Template to tier.
  public let tiers: [String: ReplayTier]

  public init(_ tiers: [String: ReplayTier]) {
    self.tiers = tiers
  }

  /// The tier a CONCRETE route needs, such as `"POST /api/v1/chat/any;-;x@example.com/read"`.
  ///
  /// **`.never` when no template matches.** A path the table does not serve is a path
  /// nothing has classified, and without a classification the only safe answer to "how far
  /// does this reach" is "too far to replay".
  ///
  /// The MOST restrictive of every template the route is an instance of, not the first:
  /// `/chat/x/typing` is an instance of both `:guid/typing` and `:guid/:messageGuid`, and
  /// the answer here must not depend on guessing which one the router prefers.
  public func tier(of route: String) -> ReplayTier {
    var found: ReplayTier?
    for (template, tier) in tiers where FixtureReplay.matches(template: template, route: route) {
      found = max(found ?? tier, tier)
    }
    return found ?? .never
  }

  /// Whether any template classifies this concrete route.
  public func classifies(_ route: String) -> Bool {
    tiers.keys.contains { FixtureReplay.matches(template: $0, route: route) }
  }
}

extension Array where Element == ReplayResult {

  /// A readable report, worst first.
  ///
  /// Ordered by how much is wrong rather than by name, because the moment this output
  /// matters is the moment a hundred lines scroll past and only the top ten get read.
  public func report(showingMatches: Bool = false, limit: Int = 12) -> String {
    var lines: [String] = []
    let compared = filter { $0.skipped == nil && $0.error == nil }
    let failing = compared.filter { !$0.isMatch }
      .sorted { ($0.differences.count, $0.fixture) > ($1.differences.count, $1.fixture) }

    for result in failing {
      var headline = "✗ \(result.fixture)\n  \(result.method) \(result.path)"
      if result.expectedStatus != result.actualStatus {
        headline += ": status \(result.expectedStatus) vs \(result.actualStatus)"
      }
      let real = result.differences.filter { $0.kind != .notCompared }
      if !real.isEmpty { headline += ": \(real.count) difference(s)" }
      lines.append(headline)
      for difference in real.prefix(limit) { lines.append("    \(difference)") }
      if real.count > limit { lines.append("    … and \(real.count - limit) more") }
    }

    if showingMatches {
      for result in compared where result.isMatch {
        lines.append("✓ \(result.method) \(result.path) (\(result.actualStatus))")
      }
    }

    let skipped = filter { $0.skipped != nil }
    if !skipped.isEmpty {
      var counts: [String: Int] = [:]
      for result in skipped { counts[result.skipped!.rawValue, default: 0] += 1 }
      lines.append("")
      for (reason, count) in counts.sorted(by: { $0.key < $1.key }) {
        lines.append("· \(count) not replayed: \(reason)")
      }
    }

    lines.append("")
    lines.append(
      "\(compared.filter(\.isMatch).count)/\(compared.count) replayed fixtures match "
        + "(\(count) in the corpus)."
    )
    return lines.joined(separator: "\n")
  }
}
