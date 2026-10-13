//  LogTailBoundsTests
//  `FileSink.tail` cannot be asked for a negative number of lines.
//
//  `Array.suffix` traps on a negative length, so `GET /api/v1/server/logs?count=-1` from any
//  authenticated client stopped the process. The route clamps, and so does this, because the
//  guarantee belongs with the function that needs it: the route was the only caller when the
//  first trap was written, and it was still the only caller when it came back.

import Foundation
import Logging
import Testing

@testable import BBDiagnostics

@Suite("Log tail bounds")
struct LogTailBoundsTests {

  private func sink() throws -> (FileSink, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-log-bounds-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("server.log")
    let sink = FileSink(url: url)
    for index in 1...5 {
      sink.write("line \(index)\n")
    }
    return (sink, directory)
  }

  @Test("A negative count returns nothing instead of trapping")
  func negativeCount() throws {
    let (sink, directory) = try sink()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(sink.tail(lines: -1).isEmpty)
    #expect(sink.tail(lines: Int.min).isEmpty)
  }

  @Test("Zero returns nothing")
  func zeroCount() throws {
    let (sink, directory) = try sink()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(sink.tail(lines: 0).isEmpty)
  }

  @Test("A positive count returns the last lines, newest last")
  func positiveCount() throws {
    let (sink, directory) = try sink()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Three, not two, for two lines of text: the split keeps the empty string after the
    // final newline, which `readLines` documents and the route's caller strips. Asserted
    // as written rather than adjusted away, because a change to that shape is one a client
    // would see as a blank trailing log line.
    let lines = sink.tail(lines: 3)
    #expect(lines.last == "")
    let text = lines.filter { !$0.isEmpty }
    #expect(text.count == 2)
    #expect(text.first?.contains("line 4") == true)
    #expect(text.last?.contains("line 5") == true)
  }

  @Test("A count past the end returns what there is")
  func countPastEnd() throws {
    let (sink, directory) = try sink()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(sink.tail(lines: 10_000).filter { !$0.isEmpty }.count == 5)
  }
}

/// A URL reaching log metadata is redacted by the RENDERER, not by each call site.
///
/// Ninety-four call sites log `String(describing: error)`, and an error's description is
/// written by whoever wrote the error rather than by the person logging it: a `URLError`
/// carries `NSErrorFailingURLKey=https://…` with the whole query string, which is where
/// clients routinely put the server password. Asking ninety-four sites to remember is how
/// one of them does not, so it happens once, where every line passes through.
///
/// `Diagnostics.init` already does exactly this for the alert path, for the same reason.
///
/// NO REAL ADDRESSES; see CONTRIBUTING.md.
@Suite("Log metadata redaction at the renderer")
struct LogMetadataRedactionTests {

  private func capture(_ body: (Logger) -> Void) -> String {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-logredact-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sink = FileSink(url: directory.appendingPathComponent("server.log"))
    var logger = Logger(label: "test") { RotatingFileLogHandler(label: $0, sink: sink) }
    logger.logLevel = .trace
    body(logger)
    // The sink writes on its own queue; drain it before reading.
    return sink.tail(lines: 50).joined(separator: "\n")
  }

  @Test("A password in a logged error's query string does not reach the file")
  func errorDescriptionIsRedacted() {
    let text = capture { logger in
      logger.warning(
        "Delivery failed",
        metadata: [
          "error": .string(
            "Error Domain=NSURLErrorDomain NSErrorFailingURLKey="
              + "https://hooks.example.com/x?password=hunter2")
        ])
    }
    #expect(!text.contains("hunter2"), "a password reached the log file: \(text)")
    #expect(text.contains("hooks.example.com"), "the endpoint must still be identifiable")
  }

  @Test("A credential in a logged URL's path does not reach the file either")
  func pathCredentialIsRedacted() {
    let text = capture { logger in
      logger.error(
        "Webhook failed",
        metadata: ["reason": .string("POST https://discord.com/api/webhooks/1/aLiveToken")])
    }
    #expect(!text.contains("aLiveToken"), "a webhook token reached the log file: \(text)")
  }

  @Test("Ordinary metadata is untouched")
  func ordinaryValuesSurvive() {
    let text = capture { logger in
      logger.info("Started", metadata: ["service": .string("app.bluebubbles.socket")])
    }
    #expect(text.contains("app.bluebubbles.socket"))
  }
}
