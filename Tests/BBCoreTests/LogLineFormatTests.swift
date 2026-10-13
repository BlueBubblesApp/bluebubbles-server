//  LogLineFormatTests
//  One format for a line of the server's log file, whichever process writes it.
//
//  The server's handler and the launcher both append to `main.log`. The launcher had its own
//  copy of the format, built on a `DateFormatter` left in the user's locale and calendar, so
//  its one line could carry an era year the server's lines did not. The format lives in
//  `LogLineFormat` now; this pins its shape and refuses a second formatter in the launcher.

import BBCore
import BBTestSupport
import Foundation
import Testing

@Suite("Log line format")
struct LogLineFormatTests {

  @Test("A line is the timestamp, the level and the label in brackets, then the message")
  func shape() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let date = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026, month: 8, day: 27, hour: 6, minute: 45, second: 32)))

    #expect(
      LogLineFormat.line(level: "info", label: "HTTPService", message: "Listening", at: date)
        == "[2026-08-27 06:45:32.000][info][HTTPService] Listening")
  }

  @Test("The launcher writes its line through the shared format, not a formatter of its own")
  func launcherHasNoFormatterOfItsOwn() throws {
    let source = try Repository.read("Sources/BlueBubblesLauncher/main.swift")
    #expect(source.contains("LogLineFormat.line("), "the scan is not reading the launcher")
    #expect(!source.contains("DateFormatter"))
  }
}
