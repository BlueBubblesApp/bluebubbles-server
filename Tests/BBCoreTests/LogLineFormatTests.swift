//  LogLineFormatTests
//  One format for a line of the server's log file, whichever process writes it.
//
//  Every writer of `main.log` goes through `LogLineFormat`. This pins its shape, including the
//  calendar: a formatter left in the user's locale writes an era year on a Mac set to a
//  Buddhist or Japanese calendar.

import BBCore
import BBTestCore
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
}
