//  LogLineTests
//  A line's level travels with it. Nothing in this process reads one back out of text.

import Logging
import Testing

@testable import BBDiagnostics

@Suite("Log line levels")
struct LogLineTests {

  @Test("A line keeps the level it was written at, whatever the text says")
  func carriesTheLevel() {
    // Nothing looks at the text. A message quoting another log line (which this server
    // does whenever it reports a subprocess's output) cannot change what the line IS.
    // A parser would have called this one an error.
    let line = LogLine(
      "[2026-09-09 09:00:00.000][info][bluebubbles.http] client said [error] oops",
      level: .info
    )
    #expect(line.level == .info)
  }

  @Test("A line written with no level has none")
  func noLevel() {
    // Nil rather than a default: a crash report or a subprocess's stderr has no level, and
    // calling it `info` would file it under a filter it does not belong to.
    #expect(LogLine("Segmentation fault: 11", level: nil).level == nil)
  }

  @Test("Every level the handler can write survives the trip")
  func everyLevel() {
    for level in Logger.Level.allCases {
      #expect(LogLine("message", level: level).level == level)
    }
  }
}
