//  LogFilteringTests
//  Which log lines the viewer shows.
//
//  `LogLevelFilter` was nested inside `LogsView`, so naming it from a test meant naming the
//  view, which traps. The two rules that are decisions rather than mechanics — that
//  `critical` belongs under Error, and that a line with NO level appears only under All —
//  had nothing on them.

import BBDiagnostics
import Logging
import Testing

@testable import BlueBubblesApp

@Suite("Log filtering")
struct LogFilteringTests {

  private func line(_ text: String, _ level: Logger.Level?) -> LogLine {
    LogLine(text, level: level)
  }

  // MARK: - Levels

  @Test("All admits every level, including one it cannot name")
  func allAdmitsEverything() {
    for level: Logger.Level? in [
      .trace, .debug, .info, .notice, .warning, .error, .critical, nil,
    ] {
      #expect(LogLevelFilter.all.admits(level), "All refused \(String(describing: level))")
    }
  }

  /// Critical is rarer and worse than error, and someone filtering to errors wants it. The
  /// only level filter that admits two.
  @Test("Error admits critical as well as error, and nothing else")
  func errorIncludesCritical() {
    #expect(LogLevelFilter.error.admits(.error))
    #expect(LogLevelFilter.error.admits(.critical))
    #expect(!LogLevelFilter.error.admits(.warning))
    #expect(!LogLevelFilter.error.admits(.info))
  }

  @Test("Info and Warning admit exactly their own level")
  func exactLevels() {
    #expect(LogLevelFilter.info.admits(.info))
    #expect(!LogLevelFilter.info.admits(.notice))
    #expect(!LogLevelFilter.info.admits(.debug))
    #expect(LogLevelFilter.warning.admits(.warning))
    #expect(!LogLevelFilter.warning.admits(.error))
  }

  /// A crash report or a subprocess's stderr has no level. It must not be filed under `info`,
  /// which is a level somebody filters BY — that would bury it for anyone narrowing down.
  @Test("A line with no level appears only under All")
  func unknownLevelOnlyUnderAll() {
    #expect(LogLevelFilter.all.admits(nil))
    for filter in [LogLevelFilter.info, .warning, .error] {
      #expect(!filter.admits(nil), "\(filter.title) admitted a line with no level")
    }
  }

  @Test("Every case has a distinct title and symbol")
  func casesAreDistinguishable() {
    let titles = LogLevelFilter.allCases.map(\.title)
    let symbols = LogLevelFilter.allCases.map(\.symbol)
    #expect(Set(titles).count == titles.count)
    #expect(Set(symbols).count == symbols.count)
  }

  // MARK: - The two filters together

  @Test("A blank query filters nothing; the level still applies")
  func blankQuery() {
    let lines = [line("a", .info), line("b", .error)]
    #expect(LogFiltering.visible(lines, level: .all, query: "").count == 2)
    #expect(LogFiltering.visible(lines, level: .error, query: "").count == 1)
  }

  /// The query is something a person typed while reading, not a pattern, so it matches
  /// without regard to case.
  @Test("The query matches without regard to case, and both filters must pass")
  func queryAndLevelTogether() {
    let lines = [
      line("Cloudflare tunnel ready", .info),
      line("cloudflare tunnel failed", .error),
      line("socket connected", .info),
    ]
    #expect(LogFiltering.visible(lines, level: .all, query: "CLOUDFLARE").count == 2)
    #expect(LogFiltering.visible(lines, level: .error, query: "cloudflare").count == 1)
    #expect(LogFiltering.visible(lines, level: .error, query: "socket").isEmpty)
  }

  @Test("Filtering preserves the order the lines were written in")
  func orderIsPreserved() {
    let lines = (0..<5).map { line("line \($0)", .info) }
    #expect(
      LogFiltering.visible(lines, level: .info, query: "line").map(\.text) == lines.map(\.text))
  }

  @Test("Nothing matching gives nothing, not everything")
  func noMatches() {
    #expect(LogFiltering.visible([line("a", .info)], level: .all, query: "zzz").isEmpty)
  }
}

/// What the viewer does with the tail, rather than with one line.
///
/// `logLines` is observable and appends constantly, so every line invalidated the view and
/// its body re-filtered the whole 2,000-line tail. With a query typed that is an ICU call per
/// line -- `localizedCaseInsensitiveContains` case-folds BOTH sides on every call -- measured
/// at 2.38ms a line, which on a busy server is a quarter of a core re-answering the same
/// question. The query is folded once now, and the result is held rather than recomputed.
@Suite("Log filtering at scale")
struct LogFilteringScaleTests {

  private func line(_ text: String, _ level: Logger.Level? = .info) -> LogLine {
    LogLine(text, level: level)
  }

  /// Folding both sides gives the same answer the ICU call gave.
  @Test("Matching is still case-insensitive")
  func caseInsensitive() {
    let lines = [line("Server STARTED on port 1234"), line("something else")]
    #expect(LogFiltering.visible(lines, level: .all, query: "started").count == 1)
    #expect(LogFiltering.visible(lines, level: .all, query: "STARTED").count == 1)
    #expect(LogFiltering.visible(lines, level: .all, query: "StArTeD").count == 1)
  }

  @Test("An empty or whitespace query filters nothing")
  func emptyQuery() {
    let lines = [line("one"), line("two"), line("three")]
    #expect(LogFiltering.visible(lines, level: .all, query: "").count == 3)
    #expect(LogFiltering.visible(lines, level: .all, query: "   ").count == 3)
  }

  @Test("The level filter still applies alongside the query")
  func levelAndQueryCompose() {
    let lines = [
      line("failed to connect", .error),
      line("failed to parse", .info),
      line("connected", .error),
    ]
    #expect(LogFiltering.visible(lines, level: .error, query: "failed").count == 1)
    #expect(LogFiltering.visible(lines, level: .all, query: "failed").count == 2)
  }

  /// The key the viewer recomputes on. The line COUNT cannot serve: once the tail is at its
  /// cap every append also drops one from the front, so a view keyed on the count would
  /// freeze at 2,000 lines and never show another.
  @Test("The filter key distinguishes a moved tail from an unchanged one")
  func keyFollowsTheVersion() {
    let a = LogFiltering.Key(level: .all, query: "", version: 1)
    #expect(a == LogFiltering.Key(level: .all, query: "", version: 1))
    #expect(a != LogFiltering.Key(level: .all, query: "", version: 2))
    #expect(a != LogFiltering.Key(level: .error, query: "", version: 1))
    #expect(a != LogFiltering.Key(level: .all, query: "x", version: 1))
  }
}
