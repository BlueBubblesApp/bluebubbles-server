//  FixtureCoverage
//  Which routes have a recorded fixture, and which do not.
//
//  Fixtures are not only test data. They are the only concrete answer to "what does this
//  endpoint actually return", which is what a client author needs and what no amount of
//  route-table metadata can supply. So the gap between the 150 routes the server serves and
//  the routes anyone has ever recorded is a documentation gap, and this measures it.
//
//  MATCHING IS DONE ON THE RECORDED PATH, not the filename. The filename encodes a query hash
//  and a status and is ambiguous — a chat GUID contains `-`, so does the hash, so does
//  `embedded-media`. `request.path` inside the fixture is authoritative.
//
//  A recorded path is CONCRETE (`/api/v1/chat/any;-;person@example.com/message`) and a route
//  is a TEMPLATE (`/api/v1/chat/:guid/message`), so matching walks the catalog in
//  registration order and takes the first template that fits — which is what the router does.
//  Matching in any other order would attribute a fixture to a route that would never have
//  served it.
//
//  See `.claude/docs/api.md`.

import BBHTTPAPI
import BBSerialization
import Foundation

public struct RouteCoverage: Sendable {
  public let method: String
  /// The router's form, with `:guid` intact.
  public let path: String
  public let group: String
  public let apiVersion: Int
  public let availabilityID: String
  public let handlerID: String
  /// Recorded statuses, ascending. Empty means nothing was ever recorded for this route.
  public let statuses: [Int]
  /// True when EVERY fixture for this route was derived from source rather than observed.
  ///
  /// Tracked because "covered" would otherwise mean two different things in one number. A
  /// derived fixture is a reading of the reference implementation, not evidence of what this
  /// server does — it cannot catch a divergence, because it was written from the same source
  /// the server was written from. Three routes are unrunnable by nature (locking the screen,
  /// restarting the server twice over) and will never be anything else, so the distinction
  /// has to survive in the report rather than being explained once and forgotten.
  public let isDerivedOnly: Bool

  public var isCovered: Bool { !statuses.isEmpty }
  /// `GET /api/v1/ping` — the form used in the allowlist file and in reports.
  public var signature: String { "\(method) \(path)" }
}

public struct CoverageReport: Sendable {
  public let routes: [RouteCoverage]
  /// Fixtures whose recorded path matched no route in the catalog. Never expected to be
  /// empty in practice — the corpus was recorded against the NODE server, which served
  /// paths this table may no longer carry — but each one is worth a look.
  public let unmatchedFixtures: [String]
  public let fixtureCount: Int

  public var covered: [RouteCoverage] { routes.filter(\.isCovered) }
  /// Covered only by a fixture written from source. See `RouteCoverage.isDerivedOnly`.
  public var derivedOnly: [RouteCoverage] { routes.filter { $0.isCovered && $0.isDerivedOnly } }
  public var uncovered: [RouteCoverage] { routes.filter { !$0.isCovered } }

  public func routes(apiVersion: Int) -> [RouteCoverage] {
    routes.filter { $0.apiVersion == apiVersion }
  }
}

public enum FixtureCoverage {

  public enum CoverageError: Error, CustomStringConvertible {
    case directoryUnreadable(String)

    public var description: String {
      switch self {
      case .directoryUnreadable(let path):
        "Cannot read the fixture directory at \(path)"
      }
    }
  }

  /// One recorded exchange, reduced to what coverage cares about.
  struct RecordedExchange {
    let method: String
    let path: String
    let status: Int
    let file: String
    /// Written from source rather than captured. Marked by a `derivedFrom` key in place of
    /// the recorder's `recordedAt`.
    let isDerived: Bool
  }

  // MARK: - Report

  public static func report(
    fixtureDirectory: String,
    entries: [RouteCatalog.Entry] = RouteCatalog.routes
  ) throws -> CoverageReport {

    let exchanges = try load(fixtureDirectory: fixtureDirectory)

    var statusesByIndex: [Int: Set<Int>] = [:]
    var recordedIndices: Set<Int> = []
    var unmatched: [String] = []

    for exchange in exchanges {
      if let index = matchIndex(for: exchange, in: entries) {
        statusesByIndex[index, default: []].insert(exchange.status)
        if !exchange.isDerived { recordedIndices.insert(index) }
      } else {
        unmatched.append("\(exchange.method) \(exchange.path)  [\(exchange.file)]")
      }
    }

    let routes = entries.enumerated().map { index, entry in
      RouteCoverage(
        method: entry.route.method.rawValue,
        path: entry.path,
        group: entry.group.name,
        apiVersion: entry.group.apiVersion,
        availabilityID: entry.availability.id,
        handlerID: entry.route.handlerID.rawValue,
        statuses: (statusesByIndex[index] ?? []).sorted(),
        isDerivedOnly: statusesByIndex[index] != nil && !recordedIndices.contains(index)
      )
    }

    return CoverageReport(
      routes: routes,
      unmatchedFixtures: unmatched.sorted(),
      fixtureCount: exchanges.count
    )
  }

  // MARK: - Loading

  static func load(fixtureDirectory: String) throws -> [RecordedExchange] {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: fixtureDirectory) else {
      throw CoverageError.directoryUnreadable(fixtureDirectory)
    }

    var exchanges: [RecordedExchange] = []
    for name in names.sorted() where name.hasSuffix(".json") {
      let full = (fixtureDirectory as NSString).appendingPathComponent(name)
      guard let data = manager.contents(atPath: full),
        let json = try? JSONValue.parse(data),
        let method = json["request"]?["method"]?.stringValue,
        let rawPath = json["request"]?["path"]?.stringValue,
        let status = json["response"]?["status"]?.intValue
      else { continue }

      exchanges.append(
        RecordedExchange(
          method: method.uppercased(),
          // The recorder writes the path with its query string attached, credentials
          // already redacted. Routing never saw the query, so neither does matching.
          path: String(rawPath.split(separator: "?", maxSplits: 1)[0]),
          status: status,
          file: name,
          // A fixture the recorder produced carries `recordedAt`; one written from source
          // carries `derivedFrom` instead, and says there why it could not be observed.
          isDerived: json["derivedFrom"] != nil
        ))
    }
    return exchanges
  }

  // MARK: - Matching

  /// The index of the first route that would have served this exchange, or nil.
  static func matchIndex(
    for exchange: RecordedExchange,
    in entries: [RouteCatalog.Entry]
  ) -> Int? {
    let actual = segments(exchange.path)
    for (index, entry) in entries.enumerated() {
      guard entry.route.method.rawValue == exchange.method else { continue }
      if matches(template: segments(entry.path), actual: actual) { return index }
    }
    return nil
  }

  static func segments(_ path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  }

  static func matches(template: [String], actual: [String]) -> Bool {
    guard template.count == actual.count else { return false }
    for (expected, found) in zip(template, actual) {
      if expected.hasPrefix(":") { continue }
      if expected != found { return false }
    }
    return true
  }
}
