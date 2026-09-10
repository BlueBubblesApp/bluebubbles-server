//  FileSinkFollowTests
//  A follower gets the tail and then every line, with nothing between them.

import BBCore
import BBDiagnostics
import Foundation
import Logging
import Testing

@Suite("File sink following")
struct FileSinkFollowTests {

  @Test("The tail is what was already written, and the stream is what comes after")
  func tailThenUpdates() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-sink-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: url) }
    let sink = FileSink(url: url)
    sink.write("one\n")
    sink.write("two\n")

    let (tail, updates) = sink.follow(tail: 1)
    // Only the last line. The tail comes from the sink's own memory, so there is no
    // trailing empty line from the file's final newline to trim.
    #expect(tail.map(\.text) == ["two"])

    // ONE write carrying two lines, which is what a multi-line log event looks like.
    sink.write("three\nfour\n")
    #expect(try await Self.next(2, from: updates).map(\.text) == ["three", "four"])
  }

  /// The tail this viewer asked for is not how far behind it may fall.
  ///
  /// They were the same number: the live stream buffered `count` lines, so this follower
  /// (asking for one line of history) could hold exactly one pending line, and the first
  /// half of the write above was dropped before anything read it. The test above caught it
  /// only when the writer won the race, and when it did the missing line did not fail an
  /// expectation, it hung the process on a stream that had gone quiet.
  @Test("A one-line tail still receives every line written after it")
  func liveBufferIsNotTheTailSize() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-sink-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: url) }
    let sink = FileSink(url: url)

    let (_, updates) = sink.follow(tail: 1)
    for index in 0..<20 { sink.write("line \(index)\n", level: .info) }
    // Drains the writer's queue before a single line is read, which is what makes this
    // deterministic. `write` is async on that queue, so without the barrier the consumer
    // usually keeps pace and the buffer never fills, which is exactly why the original
    // test only failed sometimes. Here every line is yielded before anything reads one,
    // so a buffer smaller than the burst MUST drop.
    _ = sink.tail(lines: 1)

    let lines = try await Self.next(20, from: updates)
    #expect(lines.map(\.text) == (0..<20).map { "line \($0)" })
  }

  /// Reads the next `count` lines, or fails rather than waiting for them forever.
  ///
  /// `AsyncStream.next()` on a stream that has gone quiet never returns and never
  /// cancels, so a follower that drops a line hangs the whole test process instead of
  /// failing one test: measured at over a minute of a stalled suite before it was killed
  /// by hand, with no output saying which test was stuck. Bounded, a dropped line is a red
  /// test with a name on it.
  static func next(
    _ count: Int, from updates: AsyncStream<LogLine>
  ) async throws -> [LogLine] {
    try await withTimeout(.seconds(5)) {
      var lines: [LogLine] = []
      for await line in updates {
        lines.append(line)
        if lines.count == count { break }
      }
      return lines
    }
  }

  @Test("A follower is handed the level the line was written at, in the tail and the stream")
  func levelTravelsWithTheLine() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-sink-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: url) }
    let sink = FileSink(url: url)

    // The text says nothing about a level on purpose: nothing reads it.
    sink.write("before\n", level: .error)
    let (tail, updates) = sink.follow(tail: 10)
    #expect(tail.map(\.level) == [.error])

    sink.write("after\n", level: .warning)
    let line = try #require(try await Self.next(1, from: updates).first)
    #expect(line.level == .warning)
    #expect(line.text == "after")
  }

  @Test("The tail is bounded, and holds this run's lines rather than the file's history")
  func tailIsBounded() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-sink-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: url) }
    // A file with content from a "previous run", which no viewer will be shown: those
    // lines have no level in hand and nothing parses one out of them.
    try "old line\n".write(to: url, atomically: true, encoding: .utf8)

    let sink = FileSink(url: url, recentLines: 2)
    for index in 0..<5 { sink.write("line \(index)\n", level: .info) }

    let (tail, _) = sink.follow(tail: 10)
    #expect(tail.map(\.text) == ["line 3", "line 4"])
  }

  @Test("The HTTP tail keeps its shape")
  func tailForRoutes() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-sink-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: url) }
    let sink = FileSink(url: url)
    sink.write("one\n")
    sink.write("two\n")
    // `GET /server/logs` has always answered with the split as it is, trailing empty line
    // included; the follower trims it, the route does not.
    #expect(sink.tail(lines: 2) == ["two", ""])
  }
}
