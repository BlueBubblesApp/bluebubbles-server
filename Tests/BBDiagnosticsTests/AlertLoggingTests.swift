//  AlertLoggingTests
//  Every alert reaches `main.log`, at its own severity, every time it happens.
//
//  The audit's REL-7: alerts land in `app.db`, the SwiftUI drawer and `GET /alert`, and that
//  is the whole of it. On an unattended install the drawer is UNOBSERVED rather than absent —
//  the app is running with its status item, one click away — and `GET /alert` is pull-only
//  over the same listener that is down whenever there is anything worth alerting about. So
//  the person who most needs to know is the one who is not looking.
//
//  The answer here is deliberately NOT out-of-band egress. It is the log: the artefact that
//  is already collected, already emailed in, and already the first thing anyone asks for.
//  This does not page anybody, and it is not meant to — the claim is only that a condition
//  the server raised is findable afterwards, which before this it was not.
//
//  Two holes, both of which these tests hold shut:
//
//  **Recurrences wrote nothing.** `raise` returns early when a dedupe key coalesces, and the
//  only log call was past that return. A row reading "occurred 47 times" was backed by ONE
//  line, written at the first occurrence — so an hour of a flapping proxy left an hour of
//  silence, which is the exact window somebody collects a bundle for.
//
//  **The level was fixed at `notice`.** A `.critical` and an `.info` were the same line to a
//  filter, and reading a long bundle means filtering.
//
//  And one thing that must NOT reach the log: the alert body. See `AlertCenter`'s header.

import BBCore
import Foundation
import Logging
import Testing

@testable import BBDiagnostics

@Suite("Alerts are written to the log")
struct AlertLoggingTests {

  // MARK: - The level follows the severity

  @Test("Severity picks the level, and the two that matter are not filtered away")
  func severityMapsToLevel() {
    #expect(AlertCenter.level(for: .critical) == .critical)
    #expect(AlertCenter.level(for: .error) == .error)
    #expect(AlertCenter.level(for: .warning) == .warning)
    #expect(AlertCenter.level(for: .info) == .notice)
    #expect(AlertCenter.level(for: .success) == .notice)
  }

  @Test("Every severity lands at or above `notice`, so nothing sits below the default level")
  func noAlertIsLoggedBelowNotice() {
    // The property that makes this worth doing at all. `info` and `debug` are described in
    // CLAUDE.md as one line per unit of work; an alert is by construction something shown to
    // a person, so the quietest alert still outranks the busiest ordinary line. An alert that
    // logged at `debug` would be invisible at the default level, which is the bug in a
    // different costume — the change detector's pump exit was exactly that.
    for severity in Severity.allCases {
      #expect(AlertCenter.level(for: severity) >= .notice, "\(severity) logs too quietly")
    }
  }

  @Test("A more severe alert never logs more quietly than a less severe one")
  func levelIsMonotonicInSeverity() {
    // `Severity` is `Comparable` and so is `Logger.Level`; the mapping has to respect both or
    // filtering the log by level tells you something untrue about what happened.
    let ordered = Severity.allCases.sorted()
    for (lower, higher) in zip(ordered, ordered.dropFirst()) {
      #expect(
        AlertCenter.level(for: lower) <= AlertCenter.level(for: higher),
        "\(lower) must not log louder than \(higher)")
    }
  }

  // MARK: - What actually reaches the file

  @Test("Raising an alert writes a line naming it")
  func raiseWritesALine() async {
    let log = Capture()
    let center = AlertCenter(logger: log.logger)

    await center.raise(
      UserAlert(
        severity: .error, title: "The tunnel closed", body: "unused", source: "proxy",
        diagnostics: Diagnostics(code: "proxy.closed", domain: "proxy")))

    let text = log.text()
    #expect(text.contains("The tunnel closed"))
    #expect(text.contains("proxy.closed"))
    #expect(text.contains("[error]"), "an error alert must log at error: \(text)")
  }

  @Test("A recurrence writes its own line, carrying the count")
  func recurrenceWritesALine() async {
    // The half that was missing entirely. Without it the flapping proxy that the whole
    // coalescing design exists for is the one condition the log cannot show you.
    let log = Capture()
    let center = AlertCenter(logger: log.logger)
    let alert = UserAlert(
      severity: .warning, title: "The tunnel flapped", body: "unused", source: "proxy",
      dedupeKey: "proxy.flap")

    for _ in 0..<3 { await center.raise(alert) }

    let lines = log.lines().filter { $0.contains("The tunnel flapped") }
    #expect(lines.count == 3, "each occurrence must write a line, got \(lines.count)")
    #expect(lines.last?.contains("occurrenceCount=3") == true, "\(lines)")
    #expect(lines.allSatisfy { $0.contains("[warning]") })
  }

  @Test("A critical alert logs at critical")
  func criticalLogsAtCritical() async {
    let log = Capture()
    let center = AlertCenter(logger: log.logger)

    await center.raise(
      UserAlert(severity: .critical, title: "The database is gone", body: "u", source: "db"))

    #expect(log.text().contains("[critical]"), "\(log.text())")
  }

  // MARK: - What must not reach the file

  @Test("The alert body is not logged, because bodies carry the server's own public URL")
  func bodyIsNeverLogged() async {
    // CLAUDE.md: the server's own public URL is never logged. `ProxyService` raises "…is
    // running at \(address), but the address could not be written to…", so the body of a real
    // alert on a real install contains exactly that. `Redaction.url` keeps the host — it
    // strips credentials, which is a different job — so there is no wrapping that would make
    // this safe, and the answer is not to write it.
    let log = Capture()
    let center = AlertCenter(logger: log.logger)

    await center.raise(
      UserAlert(
        severity: .error,
        title: "Could not save the server address",
        body: "Cloudflare is running at https://tunnel.example.com, but the address "
          + "could not be written to the database.",
        source: "proxy"))

    let text = log.text()
    #expect(text.contains("Could not save the server address"), "the title must be there")
    #expect(!text.contains("tunnel.example.com"), "the public URL reached the log: \(text)")
  }

  @Test("A body carrying an address is not logged either")
  func addressInBodyIsNeverLogged() async {
    // The second family of body, from `AccessControl`: "\(address) failed to authenticate…".
    // NO REAL ADDRESSES; see CONTRIBUTING.md.
    let log = Capture()
    let center = AlertCenter(logger: log.logger)

    await center.raise(
      UserAlert(
        severity: .warning, title: "An address was blocked",
        body: "192.0.2.10 failed to authenticate 12 times and is blocked.",
        source: "security"))

    #expect(!log.text().contains("192.0.2.10"), "\(log.text())")
  }
}

/// A logger that keeps what it was given, through the real handler.
///
/// Built on `RotatingFileLogHandler` and a `FileSink` rather than a bespoke recorder, so what
/// the tests read is the line that would be in `main.log` — rendering, metadata order and the
/// handler's own redaction included.
private struct Capture {
  let logger: Logger
  private let sink: FileSink

  init() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-alertlog-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sink = FileSink(url: directory.appendingPathComponent("server.log"))
    self.sink = sink
    var logger = Logger(label: "test.alerts") { RotatingFileLogHandler(label: $0, sink: sink) }
    logger.logLevel = .trace
    self.logger = logger
  }

  func lines() -> [String] { sink.tail(lines: 100) }
  func text() -> String { lines().joined(separator: "\n") }
}
