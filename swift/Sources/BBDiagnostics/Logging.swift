//  Logging
//  swift-log bootstrap. Writes to the same file path the Electron server uses, so
//  `GET /api/v1/server/logs` and everyone's muscle memory keep working.
//
//  Logging NEVER produces a user-visible notification. That is AlertCenter's job, and the
//  only way there is an explicit raise. See `.claude/docs/architecture.md`.

import Foundation
import Logging
import struct os.OSAllocatedUnfairLock

public enum LogDestination: Sendable {
  /// The path the Electron server writes to. Unchanged deliberately.
  public static var fileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/bluebubbles-server/main.log")
  }
}

/// Emits to a rotating file, matching the existing log format so an existing log reader or
/// support workflow does not have to change:
///
///     [2026-08-27 06:45:32.123][info][HTTPService] Listening on port 1234
public struct RotatingFileLogHandler: LogHandler {

  public var logLevel: Logger.Level = .info
  public var metadata: Logger.Metadata = [:]

  private let label: String
  private let sink: FileSink

  public init(label: String, sink: FileSink) {
    self.label = label
    self.sink = sink
  }

  public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  /// `log(event:)` rather than the per-argument overload, which swift-log deprecated.
  /// The event also carries `error`, so a failure logged with one reaches the file.
  public func log(event: LogEvent) {
    var merged = self.metadata
    if let explicit = event.metadata { merged.merge(explicit) { _, new in new } }
    if let error = event.error { merged["error"] = .string(String(describing: error)) }

    var line = "[\(Self.timestamp())][\(event.level)][\(label)] \(event.message)"
    if !merged.isEmpty {
      let rendered =
        merged
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: " ")
      line += " {\(rendered)}"
    }
    // The level goes with it rather than being recoverable from it. See `LogLine`.
    sink.write(line + "\n", level: event.level)
  }

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }()

  private static func timestamp() -> String {
    formatter.string(from: Date())
  }
}

/// One written line, and the level it was written at.
///
/// The level is CARRIED and never recovered. Nothing in this process reads a level back out
/// of text: the handler has it in hand when it formats the line, so it travels alongside.
/// That is not only cheaper (per line, forever, on a sink every actor writes to) it is
/// also the only version that cannot be wrong. A parser would mistake a message quoting
/// `[error]` for an error, and would break silently the day the format moved.
///
/// The file itself stays one human-readable line, because that is what somebody opens in a
/// text editor and pastes into an issue. Nothing reads it back.
/// Deliberately NOT `Identifiable`: an id would be a UUID allocated per line, on a sink
/// every actor in the process writes to. The one viewer there is renders by position.
public struct LogLine: Sendable, Equatable {

  public let text: String

  /// Nil when the writer did not have one: a crash report, a subprocess's stderr, anything
  /// written that is not a log event. Distinct from `.info` on purpose: an unknown level
  /// must not be filed under a level somebody filters by.
  public let level: Logger.Level?

  public init(_ text: String, level: Logger.Level?) {
    self.text = text
    self.level = level
  }
}

/// Append-only file writer with size-based rotation.
///
/// Serialized on its own queue: log writes come from every actor in the process and
/// interleaved partial lines are worse than useless when diagnosing a report.
public final class FileSink: @unchecked Sendable {

  private let url: URL
  private let maxBytes: Int
  private let keepRotations: Int
  private let queue = DispatchQueue(label: "bluebubbles.log.file")
  private var handle: FileHandle?
  private var bytesWritten: Int = 0
  /// Whoever is following the lines written from now on. Touched only on `queue`.
  private var followers: [UUID: AsyncStream<LogLine>.Continuation] = [:]

  /// The recent tail, in memory, so a viewer that attaches part-way through sees what it
  /// missed. Touched only on `queue`.
  ///
  /// This is what lets the level be carried rather than recovered. Reading the tail back off
  /// disk would hand a viewer text and nothing else, so it would have to parse: for lines
  /// written by this very process, whose levels were known and thrown away. Kept here
  /// instead, already structured. The file is still the file; nothing reads it back.
  ///
  /// The cost is that a viewer sees this RUN's log rather than the file's whole history.
  /// That is the right scope for a window that opens on a running server, and the file is
  /// one click away under Reveal in Finder for the rest.
  private var recent: [LogLine] = []
  private let recentCapacity: Int

  /// - Parameter recentLines: how much of the tail to hold for a viewer that attaches later.
  ///   Matches what the app keeps on screen; roughly 200 bytes a line.
  public init(
    url: URL,
    maxBytes: Int = 10 * 1024 * 1024,
    keepRotations: Int = 3,
    recentLines: Int = 2000
  ) {
    self.url = url
    self.maxBytes = maxBytes
    self.keepRotations = keepRotations
    self.recentCapacity = recentLines
    open()
  }

  /// Where the current log file is, for a "Reveal in Finder" that points at the real thing
  /// rather than at a default path that may not be the one in use.
  public var location: URL { url }

  private func open() {
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: url)
    bytesWritten = (try? handle?.seekToEnd()).map { Int($0) } ?? 0
  }

  /// Appends to the file, and hands the same line to every follower.
  ///
  /// - Parameter level: what the line was logged at, when the caller knows. Passed through
  ///   to followers rather than left to be read back out of the text; see `LogLine`. Nil
  ///   for anything written that is not a log event.
  public func write(_ string: String, level: Logger.Level? = nil) {
    queue.async { [self] in
      guard let data = string.data(using: .utf8) else { return }
      try? handle?.write(contentsOf: data)
      bytesWritten += data.count
      if bytesWritten >= maxBytes { rotate() }
      for line in string.split(separator: "\n", omittingEmptySubsequences: true) {
        let entry = LogLine(String(line), level: level)
        recent.append(entry)
        for follower in followers.values { follower.yield(entry) }
      }
      if recent.count > recentCapacity {
        recent.removeFirst(recent.count - recentCapacity)
      }
    }
  }

  /// The last `count` lines already written, and every line written after them.
  ///
  /// Both halves are taken in ONE turn of the writer's queue, so no line can land between
  /// the read and the subscription: it is in the tail or in the stream, never both and
  /// never neither. This is what lets a viewer follow the log rather than re-read the file
  /// on a timer. A follower that falls behind keeps the newest lines, because a viewer that
  /// missed a burst wants the end of it, not the start.
  /// The tail comes from memory, not from the file; see `recent`. Both halves are already
  /// structured, so no line's level is ever read back out of its text.
  ///
  /// THE LIVE BUFFER IS THE SINK'S OWN CAPACITY, NOT `count`. It was `count`, and the two
  /// are different questions: `count` is how much HISTORY this viewer asked for, and the
  /// buffer is how far behind it may fall before lines are dropped. Tied together, a
  /// follower asking for one line of history got a one-line live buffer, so a single write
  /// of two lines delivered the second and silently discarded the first, and a consumer
  /// expecting both then waited forever for a line that had already been dropped. That is
  /// the shape of the bug: not a wrong value, a stream that goes quiet.
  ///
  /// The sink's own `recentCapacity` is the right bound, because it is already the answer
  /// to "how many lines is this sink willing to hold in memory".
  public func follow(tail count: Int) -> (tail: [LogLine], updates: AsyncStream<LogLine>) {
    queue.sync {
      let (updates, continuation) = AsyncStream<LogLine>.makeStream(
        bufferingPolicy: .bufferingNewest(recentCapacity))
      let id = UUID()
      followers[id] = continuation
      // A weak reference through a `let`: the termination closure is `@Sendable`, and a
      // `weak self` capture is a var it may not read. Weak, so a follower cannot keep the
      // sink alive; the sink outlives every follower in practice, but the closure need not
      // know that.
      let sink = WeakSink(sink: self)
      continuation.onTermination = { _ in
        sink.sink?.queue.async { sink.sink?.followers[id] = nil }
      }
      return (Array(recent.suffix(count)), updates)
    }
  }

  private func rotate() {
    try? handle?.close()
    handle = nil

    let manager = FileManager.default
    // Shift .2 -> .3, .1 -> .2, current -> .1
    var index = keepRotations
    while index > 1 {
      let older = url.appendingPathExtension("\(index - 1)")
      let newer = url.appendingPathExtension("\(index)")
      if manager.fileExists(atPath: older.path) {
        try? manager.removeItem(at: newer)
        try? manager.moveItem(at: older, to: newer)
      }
      index -= 1
    }
    let first = url.appendingPathExtension("1")
    try? manager.removeItem(at: first)
    try? manager.moveItem(at: url, to: first)

    bytesWritten = 0
    open()
  }

  /// Backs `GET /api/v1/server/logs`, replacing a shell-out to `tail -n`.
  public func tail(lines count: Int) -> [String] {
    queue.sync { Array(readLines().suffix(count)) }
  }

  private struct WeakSink: Sendable {
    weak var sink: FileSink?
  }

  /// Every line in the file, including the empty one after the final newline. On `queue`.
  private func readLines() -> [String] {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }
}

public enum LoggingSystemBootstrap {

  /// The sink installed by the first bootstrap, and the level in force.
  ///
  /// `LoggingSystem.bootstrap` traps on a SECOND call ("logging system can only be
  /// initialized once per process") and that is a process-wide fact the caller cannot see.
  /// The server was bootstrapping inside composition, which is fine for the CLI, where
  /// composition happens once and the process exits. In the APP it is not: Stop and then
  /// Start builds a second server in the same process, and the app died on the precondition.
  /// Measured by pressing the buttons.
  private struct State: Sendable {
    var installed: FileSink?
    var level: Logger.Level = .info
  }

  private static let state = OSAllocatedUnfairLock(initialState: State())

  /// Installs the file handler alongside the default stream handler.
  ///
  /// Safe to call more than once: the first call wins and later ones return the same sink.
  /// A restart therefore keeps logging to the same file rather than trapping, and the level
  /// from the new settings is applied to the existing handlers rather than by re-bootstrapping.
  @discardableResult
  public static func bootstrap(level: Logger.Level = .info, fileURL: URL? = nil) -> FileSink {
    state.withLock { state in
      state.level = level
      if let installed = state.installed {
        // A second composition in the same process: the app's Stop/Start. The handlers
        // are already installed and cannot be replaced, so only the level moves.
        return installed
      }

      let sink = FileSink(url: fileURL ?? LogDestination.fileURL)
      LoggingSystem.bootstrap { label in
        var fileHandler = RotatingFileLogHandler(label: label, sink: sink)
        var streamHandler = StreamLogHandler.standardOutput(label: label)
        // The children never filter. The gate is the wrapper's dynamic level, and a child
        // with its own threshold would silently re-filter below it.
        fileHandler.logLevel = .trace
        streamHandler.logLevel = .trace
        return DynamicLevelLogHandler(handlers: [fileHandler, streamHandler])
      }
      state.installed = sink
      return sink
    }
  }

  /// Changes the level every logger uses, immediately.
  ///
  /// This is what makes the Log Level setting mean something. Without it the level comes
  /// from `ServerComposition.Options`, which nothing populates from the store, so a user
  /// turns on debug logging, sees no new lines, and reasonably concludes logging is broken.
  /// It is also the setting people reach for at precisely the moment they are trying to
  /// diagnose something else.
  public static func setLevel(_ level: Logger.Level) {
    state.withLock { $0.level = level }
  }

  /// The level in force. Read on every log call through `DynamicLevelLogHandler`.
  fileprivate static var currentLevel: Logger.Level { state.withLock { $0.level } }
}

/// A multiplexer whose level is read from `LoggingSystemBootstrap` on every call.
///
/// swift-log gives no way to reach back into handlers already handed out, so a level stored on
/// the handler is fixed for the life of every `Logger` created before the change. Making the
/// getter dynamic sidesteps that: `Logger` consults `handler.logLevel` on each call, so raising
/// the level takes effect on loggers that already exist, which is every logger in a running
/// server.
struct DynamicLevelLogHandler: LogHandler {

  var handlers: [any LogHandler]
  var metadata: Logger.Metadata = [:]

  var logLevel: Logger.Level {
    get { LoggingSystemBootstrap.currentLevel }
    // Ignored deliberately. The level is a server-wide setting, and letting one call site
    // set its own would make the setting silently untrue for that logger.
    set {}
  }

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    for handler in handlers {
      handler.log(event: event)
    }
  }
}
