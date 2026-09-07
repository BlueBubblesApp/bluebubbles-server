//  LogLevelWiringTests
//  That the Log Level setting reaches the logging system.
//
//  The audit found this one dead: the level came from `ServerComposition.Options`, which nothing
//  populated from the store, so the Debug tab's picker controlled nothing. It is also the
//  setting people reach for at exactly the moment they are trying to diagnose something else,
//  which makes a silent failure here unusually expensive.
//
//  Serialized because the logging system is process-wide: this suite moves a global level, and
//  restores it.

import BBDiagnostics
import BBSettings
import Foundation
import Logging
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Log level wiring", .serialized)
struct LogLevelWiringTests {

  @Test("A logger created BEFORE the change respects the new level")
  func levelAppliesToExistingLoggers() throws {
    // The property the whole feature rests on. swift-log gives no way to reach into a
    // handler already handed out, so a level stored on the handler is fixed for the life
    // of every logger built before the change — and every logger in a running server was
    // built at startup. Reading it dynamically is what makes raising the level mid-session
    // do anything.
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sink = LoggingSystemBootstrap.bootstrap(
      level: .info, fileURL: directory.appendingPathComponent("test.log")
    )
    let logger = Logger(label: "test.dynamic.\(UUID().uuidString)")
    let marker = UUID().uuidString

    LoggingSystemBootstrap.setLevel(.info)
    logger.debug("suppressed-\(marker)")

    LoggingSystemBootstrap.setLevel(.debug)
    logger.debug("emitted-\(marker)")

    LoggingSystemBootstrap.setLevel(.info)

    let contents = sink.tail(lines: 500).joined(separator: "\n")
    #expect(!contents.contains("suppressed-\(marker)"))
    #expect(contents.contains("emitted-\(marker)"))
  }

  @Test("Every option the picker offers parses")
  func everyPickerOptionParses() {
    // The picker's values and the parse have to agree. A value that fails to parse falls
    // back to `.info`, which would look exactly like the setting not working.
    guard case .picker(let options) = Settings.logLevel.presentation?.control else {
      Issue.record("log_level is no longer a picker")
      return
    }
    for option in options {
      let parsed = Settings.logLevel(from: option.value).rawValue
      let offered = option.value
      #expect(parsed == offered, "a picker option does not parse back to itself")
    }
  }

  @Test("An unrecognised stored value falls back rather than crashing")
  func unknownLevelFallsBack() {
    #expect(Settings.logLevel(from: "nonsense") == .info)
    #expect(Settings.logLevel(from: "DEBUG") == .debug)
  }

  @Test("A change to the level is applied live, not on restart")
  func levelIsPropagatedLive() {
    // In `unownedKeys` rather than a service's `watchedSettings`: the logging system is
    // process-wide and older than any service, so no service owns it.
    #expect(SettingsPropagation.unownedKeys.contains("log_level"))
    #expect(!SettingsPropagation.structuralKeys.contains("log_level"))
  }
}
