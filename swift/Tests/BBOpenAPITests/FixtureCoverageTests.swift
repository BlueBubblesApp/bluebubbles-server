//  FixtureCoverageTests
//  The matcher, which is the part of coverage that can be wrong without looking wrong.
//
//  A miscounted report is worse than no report: it either hides a gap or invents one, and
//  nobody re-derives it by hand to find out. The properties asserted here are the ones the
//  count depends on — template matching, first-match-wins order, and the query string not
//  participating.

import BBHTTPAPI
import BBSerialization
import Foundation
import Testing

@testable import BBOpenAPI

@Suite("Fixture coverage matching")
struct FixtureCoverageTests {

  private func exchange(_ method: String, _ path: String, status: Int = 200)
    -> FixtureCoverage.RecordedExchange
  {
    FixtureCoverage.RecordedExchange(
      method: method, path: path, status: status, file: "test.json", isDerived: false)
  }

  @Test("A concrete path matches its template")
  func matchesTemplate() {
    #expect(
      FixtureCoverage.matches(
        template: ["api", "v1", "chat", ":guid", "message"],
        actual: ["api", "v1", "chat", "any;-;person@example.com", "message"]
      ))
  }

  @Test("Segment count must agree")
  func rejectsDifferentLengths() {
    #expect(
      !FixtureCoverage.matches(
        template: ["api", "v1", "chat", ":guid"],
        actual: ["api", "v1", "chat", "abc", "message"]
      ))
  }

  @Test("A literal segment must match exactly")
  func rejectsWrongLiteral() {
    #expect(
      !FixtureCoverage.matches(
        template: ["api", "v1", "chat", "count"],
        actual: ["api", "v1", "chat", "abc"]
      ))
  }

  @Test("The first matching route wins, as the router does")
  func firstMatchWins() {
    // `GET /chat/count` and `GET /chat/:guid` both match the path `/api/v1/chat/count`.
    // The router registers `count` first and serves it, so coverage has to attribute the
    // fixture there — crediting `:guid` would report the literal route as uncovered while
    // claiming a parameterised route was exercised by a request that never reached it.
    let entries = RouteCatalog.routes
    let index = FixtureCoverage.matchIndex(
      for: exchange("GET", "/api/v1/chat/count"), in: entries
    )
    let matched = try! #require(index.map { entries[$0] })
    #expect(matched.route.handlerID.rawValue == "chat.count")
  }

  @Test("Method is part of the match")
  func methodMatters() {
    let entries = RouteCatalog.routes
    let index = FixtureCoverage.matchIndex(
      for: exchange("DELETE", "/api/v1/chat/any;-;x/typing"), in: entries
    )
    let matched = try! #require(index.map { entries[$0] })
    #expect(matched.route.handlerID.rawValue == "chat.stopTyping")
  }

  @Test("The landing page matches the root route")
  func rootMatches() {
    let entries = RouteCatalog.routes
    let index = FixtureCoverage.matchIndex(for: exchange("GET", "/"), in: entries)
    let matched = try! #require(index.map { entries[$0] })
    #expect(matched.route.handlerID.rawValue == "ui.index")
  }

  @Test("An unknown path matches nothing rather than the nearest route")
  func unknownPathIsUnmatched() {
    #expect(
      FixtureCoverage.matchIndex(
        for: exchange("GET", "/api/v1/nonexistent"), in: RouteCatalog.routes
      ) == nil)
  }

  @Test("Recorded fixtures are attributed to real routes")
  func reportsAgainstTheRealCorpus() throws {
    // Runs against the committed corpus. Not asserting a coverage NUMBER — that changes
    // every time somebody records a fixture, which is the point of the exercise — only
    // that the corpus parses and lands somewhere in the table.
    let report = try FixtureCoverage.report(
      fixtureDirectory: fixturesPath, entries: RouteCatalog.routes
    )
    #expect(report.fixtureCount > 0, "no fixtures were read from \(fixturesPath)")
    #expect(!report.covered.isEmpty)
    #expect(report.routes.count == RouteCatalog.routes.count)
  }

  /// The corpus lives at `swift/Fixtures/http`, outside every target, so it is reached by
  /// path from this file rather than through `Bundle.module`.
  private var fixturesPath: String {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // BBOpenAPITests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .appendingPathComponent("Fixtures/http")
      .path
  }
}

@Suite("Derived fixtures are not counted as observed")
struct DerivedFixtureTests {

  /// Three routes cannot be run to record them: one locks the screen, two restart the
  /// server. Their responses are fully determined by the reference source — each returns
  /// before doing the destructive thing — so they are written from it instead.
  ///
  /// Which makes the distinction worth keeping. A derived fixture is a reading of the
  /// reference implementation, not evidence of what this server does: it was written from
  /// the same source the server was written from, so it cannot catch a divergence between
  /// them. Counting it as "covered" without saying so would let one number mean two things.
  @Test("A fixture written from source is marked, and the marker is the absence of a recording")
  func derivedIsDistinguishable() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/http")

    var derived = 0
    for file in try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    where file.pathExtension == "json" {
      let json = try JSONValue.parse(try Data(contentsOf: file))
      let isDerived = json["derivedFrom"] != nil
      if isDerived {
        derived += 1
        // A derivation has to say where it came from and why it was not observed, or it is
        // indistinguishable from a guess.
        #expect(json["derivedFrom"]?["source"]?.stringValue?.isEmpty == false)
        #expect(json["derivedFrom"]?["reason"]?.stringValue?.isEmpty == false)
        // And it must NOT claim to have been recorded.
        #expect(json["recordedAt"] == nil, "\(file.lastPathComponent) claims both")
      }
    }
    #expect(derived > 0, "no derived fixtures found; the marker may have been renamed")
  }

  @Test("The report separates derived routes from observed ones")
  func reportSeparatesThem() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/http").path
    let report = try FixtureCoverage.report(fixtureDirectory: root)
    // Every derived-only route is still covered — the point is that it is ALSO flagged.
    for route in report.derivedOnly { #expect(route.isCovered) }
    #expect(report.derivedOnly.count < report.covered.count, "everything cannot be derived")
  }
}
