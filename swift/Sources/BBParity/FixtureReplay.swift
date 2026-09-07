//  FixtureReplay
//  Issues a recorded request against a running server and diffs the answer.
//
//  This is the piece `CompatibilityContractTests` claimed to be and was not. The corpus was
//  recorded, committed, scanned for personal data — and never fed back into anything. The
//  compatibility contract was enforced on one afternoon, by hand, through `bb-parity`, and
//  has been inert since.
//
//  Two callers, deliberately:
//
//  - `Tests/CompatibilityTests/FixtureReplayTests` mounts the real router in-process over a
//    synthetic `chat.db` and runs the whole corpus on every CI build. It compares SHAPE,
//    because the fixtures were recorded against a real Mac's messages and this one has seven.
//  - `bb-parity replay --candidate …` runs the same corpus against a server holding real
//    data, where the comparison can be strict.
//
//  One implementation for both, for the reason `ResponseDiff` is shared: two copies would
//  drift, and the drift would be silent.

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
  }

  /// Whether the two agree. A skipped fixture is not a match — it is an absence of one.
  public var isMatch: Bool {
    skipped == nil && error == nil && expectedStatus == actualStatus
      && differences.allSatisfy { $0.kind == .notCompared }
  }

  /// A body difference that is not merely "the status already told us so".
  public var hasBodyDifferences: Bool {
    differences.contains { $0.kind != .notCompared }
  }
}

public struct FixtureReplay: Sendable {

  private let baseURL: String
  private let password: String
  private let mode: DiffMode
  private let session: URLSession

  /// - Parameter mode: `.shape` when the server under test holds different data from the
  ///   one the corpus was recorded against, which is every in-process run.
  public init(baseURL: String, password: String, mode: DiffMode = .shape) {
    self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    self.password = password
    self.mode = mode

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    self.session = URLSession(configuration: configuration)
  }

  public func run(_ fixtures: [RecordedFixture]) async -> [ReplayResult] {
    var results: [ReplayResult] = []
    // Sequential. Several of these fixtures write to the server's own database — a
    // webhook, a theme, a scheduled message — and running them concurrently would let one
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
    if Self.isDestructive(fixture) { return .destructive }
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
    var components = URLComponents(string: baseURL + fixture.request.routePath)
    var items = fixture.request.queryItemsWithoutPassword
    items.append(URLQueryItem(name: "password", value: password))
    components?.queryItems = items

    guard let url = components?.url else {
      throw ReplayError.badURL(baseURL + fixture.request.path)
    }

    var request = URLRequest(url: url)
    request.httpMethod = fixture.request.method
    if case .json(let encoded) = fixture.request.body {
      request.httpBody = Data(encoded.utf8)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return (status, object, String(decoding: data, as: UTF8.self))
  }

  /// Routes that act on the machine, refused before the request is built.
  ///
  /// **This is not a nicety.** The first run of this harness locked the developer's Mac —
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
    // Tears down every service, or the whole process, under the test that is driving it.
    "GET /api/v1/server/restart/soft",
    "GET /api/v1/server/restart/hard",
    // Downloads and installs a new build of the server.
    "POST /api/v1/server/update/install",
  ]

  /// Anything that could put a message in front of a real person, plus the deny-list.
  ///
  /// The corpus is documented as read-only and mostly is, but the send fixtures were
  /// recorded and committed, and "the helper is not connected so it will fail anyway" is an
  /// assumption about the machine the test runs on, not a property of the test. The
  /// AppleScript backend needs no helper.
  public static func isDestructive(_ fixture: RecordedFixture) -> Bool {
    let route = "\(fixture.request.method) \(fixture.request.routePath)"
    if destructiveRoutes.contains(route) { return true }

    guard fixture.request.method != "GET" else { return false }
    // The reads that happen to be POSTs. Carved out by name rather than by pattern: these
    // are the most valuable comparisons in the corpus — they are the ones that return
    // entities — and a prefix rule broad enough to be safe swallows all four of them.
    if readOnlyWrites.contains(route) { return false }
    return sendingPrefixes.contains { fixture.request.routePath.hasPrefix($0) }
  }

  /// Non-GET routes that read and nothing more.
  public static let readOnlyWrites: Set<String> = [
    "POST /api/v1/message/query",
    "POST /api/v1/chat/query",
    "POST /api/v1/handle/query",
    "POST /api/v1/contact/query",
  ]

  /// Path prefixes whose non-GET routes reach Messages or FaceTime.
  public static let sendingPrefixes: [String] = [
    "/api/v1/message/", "/api/v2/message/",
    "/api/v1/chat/", "/api/v2/chat/",
    "/api/v1/facetime/", "/api/v2/facetime/",
    "/api/v1/handle/", "/api/v1/icloud/",
  ]

  public enum ReplayError: Error, CustomStringConvertible {
    case badURL(String)
    public var description: String {
      switch self {
      case .badURL(let url): "Could not build a URL from \(url)"
      }
    }
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
        headline += " — status \(result.expectedStatus) vs \(result.actualStatus)"
      }
      let real = result.differences.filter { $0.kind != .notCompared }
      if !real.isEmpty { headline += " — \(real.count) difference(s)" }
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
