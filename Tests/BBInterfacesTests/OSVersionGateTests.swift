//  OSVersionGateTests
//  Every macOS gate in the interfaces layer reads the version it was given, never the host's.
//
//  A gate that reads `ProcessInfo` can be tested for one answer only, the one this Mac gives,
//  and a gate that has only ever run on the release it permits is not a gate anybody has
//  checked. `MessageInterface` and `ChatInterface` each hold an injected `osMajorVersion` for
//  this, and three of the gates beside it (Send Later, emoji reactions, text formatting) read
//  the host anyway. The scan below keeps `operatingSystemVersion` to the one place a version is
//  injected from.

import BBPrivateAPIContract
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces

@Suite("macOS version gates")
struct OSVersionGateTests {

  @Test("Text formatting is refused on Sonoma and passes on Sequoia, whatever this Mac runs")
  func textFormatting() throws {
    let bold = [FormattedRange(start: 0, length: 4, styles: [.bold])]
    #expect(throws: InterfaceError.self) {
      try MessageInterface.checkFormatting(bold, text: "BB test", majorVersion: 14)
    }
    try MessageInterface.checkFormatting(bold, text: "BB test", majorVersion: 15)
    // No ranges, no gate: a plain send is not a formatted one.
    try MessageInterface.checkFormatting([], text: "BB test", majorVersion: 14)
  }

  @Test("Send Later is refused on Sonoma and passes on Sequoia, whatever this Mac runs")
  func sendLater() throws {
    #expect(throws: InterfaceError.self) {
      try MessageInterface.checkSendLaterSupported(majorVersion: 14, schemaRecordsSchedules: true)
    }
    try MessageInterface.checkSendLaterSupported(majorVersion: 15, schemaRecordsSchedules: true)
    // The other half: a database without the schedule columns cannot be read for them,
    // whatever the system could schedule.
    #expect(throws: InterfaceError.self) {
      try MessageInterface.checkSendLaterSupported(majorVersion: 15, schemaRecordsSchedules: false)
    }
  }

  @Test("A Send Later date in the past is refused, with a minute of slack for clock skew")
  func scheduledDate() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    try MessageInterface.checkScheduledDate(now.addingTimeInterval(3600), now: now)
    try MessageInterface.checkScheduledDate(now.addingTimeInterval(-30), now: now)
    #expect(throws: InterfaceError.self) {
      try MessageInterface.checkScheduledDate(now.addingTimeInterval(-3600), now: now)
    }
  }

  @Test("No interface reads the host's macOS version outside an injection default")
  func noGateReadsTheHost() throws {
    // Not a gate: Game Pigeon's payload carries the sending OS as a version STRING, so this
    // is a wire value describing the host, which is exactly what it should read.
    let allowed: Set<String> = ["Sources/BBInterfaces/AppMessageInterface.swift"]

    let files = try SourceScanner.swiftFiles(under: "Sources/BBInterfaces", minimum: 11)
      .filter { !allowed.contains($0.path) }
    let offences = SourceScanner.offences(in: files) { _, line in
      let code = line.code.trimmingCharacters(in: .whitespaces)
      // The injection point: an initialiser's default for the stored `osMajorVersion`.
      return code.contains("operatingSystemVersion") && !code.hasPrefix("osMajorVersion: Int = ")
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue:
          "a gate reads the host's macOS version; take `majorVersion` and pass `osMajorVersion`:\n"
          + offences.report)
    )
  }
}
