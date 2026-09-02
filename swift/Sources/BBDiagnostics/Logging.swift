//  Logging
//  swift-log bootstrap. Writes to the same file path the Electron server uses, so
//  `GET /api/v1/server/logs` and everyone's muscle memory keep working.
//
//  Logging NEVER produces a user-visible notification. That is AlertCenter's job, and the
//  only way there is an explicit raise. See `.claude/docs/architecture.md`.

import Foundation
import Logging

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
  /// The event also carries `error`, which the old signature had nowhere to put — so a
  /// failure logged with one now reaches the file instead of being dropped.
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
    sink.write(line + "\n")
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

  public init(url: URL, maxBytes: Int = 10 * 1024 * 1024, keepRotations: Int = 3) {
    self.url = url
    self.maxBytes = maxBytes
    self.keepRotations = keepRotations
    open()
  }

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

  public func write(_ string: String) {
    queue.async { [self] in
      guard let data = string.data(using: .utf8) else { return }
      try? handle?.write(contentsOf: data)
      bytesWritten += data.count
      if bytesWritten >= maxBytes { rotate() }
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
    queue.sync {
      guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
      let all = contents.split(separator: "\n", omittingEmptySubsequences: false)
      return all.suffix(count).map(String.init)
    }
  }
}

public enum LoggingSystemBootstrap {

  /// The sink installed by the first bootstrap.
  ///
  /// `LoggingSystem.bootstrap` traps on a SECOND call — "logging system can only be
  /// initialized once per process" — and that is a process-wide fact the caller cannot see.
  /// The server was bootstrapping inside composition, which is fine for the CLI, where
  /// composition happens once and the process exits. In the APP it is not: Stop and then
  /// Start builds a second server in the same process, and the app died on the precondition.
  /// Measured by pressing the buttons.
  ///
  /// `nonisolated(unsafe)` is honest here: written once behind the flag below, read after.
  private nonisolated(unsafe) static var installed: FileSink?
  private static let lock = NSLock()

  /// Installs the file handler alongside the default stream handler.
  ///
  /// Safe to call more than once: the first call wins and later ones return the same sink.
  /// A restart therefore keeps logging to the same file rather than trapping — and the level
  /// from the new settings is applied to the existing handlers rather than by re-bootstrapping.
  @discardableResult
  public static func bootstrap(level: Logger.Level = .info, fileURL: URL? = nil) -> FileSink {
    lock.lock()
    defer { lock.unlock() }

    if let installed {
      // A second composition in the same process — the app's Stop/Start. The handlers
      // are already installed and cannot be replaced, so only the level moves.
      currentLevel = level
      return installed
    }

    let sink = FileSink(url: fileURL ?? LogDestination.fileURL)
    currentLevel = level
    LoggingSystem.bootstrap { label in
      var fileHandler = RotatingFileLogHandler(label: label, sink: sink)
      var streamHandler = StreamLogHandler.standardOutput(label: label)
      // The children never filter. The gate is the wrapper's dynamic level, and a child
      // with its own threshold would silently re-filter below it.
      fileHandler.logLevel = .trace
      streamHandler.logLevel = .trace
      return DynamicLevelLogHandler(handlers: [fileHandler, streamHandler])
    }
    installed = sink
    return sink
  }

  /// Changes the level every logger uses, immediately.
  ///
  /// This is what makes the Log Level setting mean something. Without it the level comes
  /// from `ServerComposition.Options`, which nothing populates from the store — so a user
  /// turns on debug logging, sees no new lines, and reasonably concludes logging is broken.
  /// It is also the setting people reach for at precisely the moment they are trying to
  /// diagnose something else.
  public static func setLevel(_ level: Logger.Level) {
    lock.lock()
    defer { lock.unlock() }
    currentLevel = level
  }

  /// The level in force. Read on every log call through `DynamicLevelLogHandler`.
  fileprivate nonisolated(unsafe) static var currentLevel: Logger.Level = .info
}

/// A multiplexer whose level is read from `LoggingSystemBootstrap` on every call.
///
/// swift-log gives no way to reach back into handlers already handed out, so a level stored on
/// the handler is fixed for the life of every `Logger` created before the change. Making the
/// getter dynamic sidesteps that: `Logger` consults `handler.logLevel` on each call, so raising
/// the level takes effect on loggers that already exist — which is every logger in a running
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
