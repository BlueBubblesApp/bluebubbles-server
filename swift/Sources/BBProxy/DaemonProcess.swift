//  DaemonProcess
//  One supervisor for the external binaries the tunnels are.
//
//  All three tunnel services drive a bundled executable, and today each reimplements the same
//  lifecycle badly: spawn, scrape stdout for a URL, notice it died, restart. The ngrok path
//  additionally goes through an npm binding while cloudflared and zrok are spawned directly,
//  so "the tunnel process crashed" behaves differently depending on which tunnel you chose.
//
//  Unifying them means the restart policy, the output scraping, and the crash handling are
//  written once and are the same for all three.
//
//  See `.claude/docs/performance.md`.

import BBCore
import Darwin
import Foundation
import Logging

public enum DaemonError: BBError, Equatable {
  case executableMissing(path: String)
  case launchFailed(reason: String)
  case exitedBeforeReady(code: Int32, output: String)
  case readyTimeout(after: Duration)
}

/// What a daemon is waiting to see before it counts as up.
public struct ReadinessSignal: Sendable {
  /// Applied to each line of output; returns the extracted value when the line is the one.
  public let match: @Sendable (String) -> String?
  public let timeout: Duration

  public init(timeout: Duration = .seconds(60), match: @escaping @Sendable (String) -> String?) {
    self.timeout = timeout
    self.match = match
  }
}

public struct DaemonConfiguration: Sendable {
  public let name: String
  public let executablePath: String
  public let arguments: [String]
  public let environment: [String: String]
  /// Restart backoff after an unexpected exit.
  public let restartDelay: Duration
  public let maximumRestarts: Int
  /// A gap longer than this resets the restart count — the same distinction the dylib
  /// injector draws between "broken" and "ran for a while and then crashed".
  public let restartWindow: Duration

  public init(
    name: String,
    executablePath: String,
    arguments: [String] = [],
    environment: [String: String] = [:],
    restartDelay: Duration = .seconds(5),
    maximumRestarts: Int = 10,
    restartWindow: Duration = .seconds(300)
  ) {
    self.name = name
    self.executablePath = executablePath
    self.arguments = arguments
    self.environment = environment
    self.restartDelay = restartDelay
    self.maximumRestarts = maximumRestarts
    self.restartWindow = restartWindow
  }
}

/// Bytes taken off a daemon's pipe but not yet folded into the actor's state.
///
/// This exists because the two readers of that pipe are both OUTSIDE the actor — the
/// readability handler, on a background queue, and the drain at termination — while everything
/// that interprets what they read is inside it. Handing bytes across that boundary through a
/// `Task` loses the race for a process that prints its error and exits immediately: the
/// termination path runs first, finds a pipe the handler has already emptied, and reports the
/// failure with no output at all. That output is the entire diagnosis — "ngrok exited with 1"
/// tells a user nothing, while the line above it names the expired authtoken.
///
/// So the bytes are captured synchronously, under a lock held across the READ as well as the
/// append. Locking only the append would leave the same race in a smaller window: a handler
/// suspended between `availableData` and storing what it read still holds the only copy.
private final class PipeBuffer: @unchecked Sendable {

  private let lock = NSLock()
  private var text = ""

  /// Takes what is available now. Called from the readability handler.
  func absorbAvailable(from handle: FileHandle) {
    lock.lock()
    defer { lock.unlock() }
    let data = handle.availableData
    guard !data.isEmpty else { return }
    text += String(decoding: data, as: UTF8.self)
  }

  /// Takes whatever is on the pipe right now, without waiting for more.
  ///
  /// Non-blocking, and that is the whole point of doing it by hand rather than through
  /// `FileHandle.read(upToCount:)`.
  ///
  /// A pipe's read end reports EOF only once EVERY writer has closed it — and the daemon's
  /// own children inherit that write end. `Process.terminate()` signals the daemon and not
  /// its children (deliberately; see `stop()`), so a tunnel that leaves one behind leaves a
  /// process holding the pipe open, and a blocking read waits for a writer that is never
  /// coming back.
  ///
  /// It waited on the actor, which made it far worse than slow: `handleTermination` calls
  /// this, so one orphaned child froze the whole `DaemonProcess` — including the reconnect
  /// that was supposed to bring the tunnel back. A test with a shell that forks `sleep 20`
  /// took twenty seconds to disconnect; with `exec`, half a second.
  ///
  /// Reading only what is buffered loses nothing in practice: a process that has exited has
  /// already completed its writes, and anything arriving later is still picked up by the
  /// readability handler.
  func absorbRemaining(from handle: FileHandle) {
    lock.lock()
    defer { lock.unlock() }

    let descriptor = handle.fileDescriptor
    guard descriptor >= 0 else { return }

    // `poll` with a zero timeout rather than switching the descriptor to non-blocking.
    //
    // Setting O_NONBLOCK would work for this loop and break the OTHER reader: the
    // readability handler runs on its own queue and calls `availableData`, which behaves
    // differently on a non-blocking descriptor. Changing a flag one thread depends on
    // while it is using it trades a hang for something rarer and harder to find. `poll`
    // asks the same question and mutates nothing.
    //
    // Reading under the lock is what makes "poll said readable, so read will not block"
    // true: the readability handler takes the same lock, so it cannot empty the pipe
    // between the two calls.
    var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    while poll(&descriptors, 1, 0) > 0 {
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      // 0 is EOF — every writer has gone. -1 is an error, including the EAGAIN that a
      // spurious wakeup produces. Both end the drain.
      guard count > 0 else { return }
      text += String(decoding: buffer[0..<count], as: UTF8.self)
    }
  }

  /// Everything buffered so far, leaving the buffer empty.
  func take() -> String {
    lock.lock()
    defer {
      text = ""
      lock.unlock()
    }
    return text
  }
}

public actor DaemonProcess {

  private let configuration: DaemonConfiguration
  private let logger: Logger
  /// Called when the process dies without anyone having asked it to.
  ///
  /// A `var` rather than a `let` so it can be replaced after construction — see
  /// `onTermination(_:)`.
  private var onExit: @Sendable (Int32) async -> Void

  private var process: Process?
  /// Retained so the last of its output can be drained at termination — see
  /// `handleTermination`.
  private var outputPipe: Pipe?
  /// See `PipeBuffer`: bytes are captured off the pipe synchronously and folded in here
  /// afterwards, so a daemon that dies immediately still carries its own explanation.
  private nonisolated let pipeBuffer = PipeBuffer()
  private var outputLines: [String] = []
  private var readyContinuation: CheckedContinuation<String, any Error>?
  private var readiness: ReadinessSignal?
  /// A readiness value that arrived before anyone was waiting for it.
  ///
  /// The continuation is registered from a detached task, so there is a window between the
  /// process starting and the waiter being installed. A fast daemon — or a loaded machine —
  /// prints its URL inside that window, and without somewhere to put it the match is
  /// discarded and the wait times out despite the daemon being perfectly healthy.
  private var pendingReadyValue: String?
  /// A TERMINATION that arrived before anyone was waiting for it.
  ///
  /// The exact mirror of `pendingReadyValue`, and it is missing for the same reason it was
  /// needed there: the waiter is registered from a detached task, so a daemon that fails
  /// instantly — a bad authtoken, a port already forwarded — can be dead before anyone is
  /// listening. The success case was noticed and buffered; the failure case was dropped, and
  /// the caller then waited out the WHOLE readiness timeout and was told the tunnel "did not
  /// report a URL within 60 seconds". Sixty seconds, and the wrong reason: the daemon had
  /// printed the real one and exited a moment after being launched.
  private var pendingExit: DaemonError?
  private var isStopping = false
  private var restartCount = 0
  private var lastExitAt: ContinuousClock.Instant?

  /// Bounded, because a chatty daemon left running for weeks would otherwise grow this
  /// without limit. Recent lines are what a diagnostic report needs; older ones are noise.
  private static let retainedLines = 200

  public init(
    configuration: DaemonConfiguration,
    logger: Logger = Logger(label: "bluebubbles.proxy.daemon"),
    onExit: @escaping @Sendable (Int32) async -> Void = { _ in }
  ) {
    self.configuration = configuration
    self.logger = logger
    self.onExit = onExit
  }

  public var isRunning: Bool { process?.isRunning ?? false }
  public var recentOutput: [String] { outputLines }

  /// Replaces the unexpected-exit handler.
  ///
  /// Settable after construction, rather than only through `init`, because the object that
  /// wants to know is the one that OWNS this process: `BinaryTunnel` stores a
  /// `DaemonProcess`, so a closure capturing the tunnel cannot be passed to the initialiser
  /// of the tunnel's own stored property. The alternative — making the daemon optional and
  /// building it inside `connect()` — spreads that one ordering problem across every method
  /// that touches it.
  public func onTermination(_ handler: @escaping @Sendable (Int32) async -> Void) {
    onExit = handler
  }

  /// Starts the process and waits for its readiness signal.
  ///
  /// Returns whatever the signal extracted — for a tunnel, the public URL it printed.
  @discardableResult
  public func start(waitingFor signal: ReadinessSignal? = nil) async throws -> String? {
    guard process == nil else { return nil }
    guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
      throw DaemonError.executableMissing(path: configuration.executablePath)
    }

    isStopping = false
    readiness = signal
    pendingReadyValue = nil
    pendingExit = nil
    outputLines.removeAll()
    // Anything left by a previous run, which would otherwise be reported as this one's.
    _ = pipeBuffer.take()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: configuration.executablePath)
    process.arguments = configuration.arguments
    process.environment = ProcessInfo.processInfo.environment
      .merging(configuration.environment) { _, new in new }

    // Its own process group, so the whole tree can be signalled later.
    //
    // These binaries spawn children — cloudflared runs helpers, and anything launched
    // through a shell wrapper has at least one. `Process.terminate()` signals only the
    // direct child, so without this the grandchildren survive, keep the output pipe
    // open, and go on holding a tunnel we believe we closed.
    // Detached from our stdin so a daemon that reads it cannot block on the server's.
    process.standardInput = FileHandle.nullDevice

    let pipe = Pipe()
    process.standardOutput = pipe
    // Merged deliberately: these binaries print their URL to one stream and their errors
    // to the other, and which is which differs between them and between versions.
    process.standardError = pipe

    // The buffer is captured directly rather than reached through `self`: the read has to
    // happen synchronously here, and it has to survive the actor having gone away.
    pipe.fileHandleForReading.readabilityHandler = { [weak self, buffer = pipeBuffer] handle in
      buffer.absorbAvailable(from: handle)
      Task { await self?.ingestBuffered() }
    }

    process.terminationHandler = { [weak self] finished in
      Task { await self?.handleTermination(code: finished.terminationStatus) }
    }

    do {
      try process.run()
    } catch {
      throw DaemonError.launchFailed(reason: String(describing: error))
    }
    self.process = process
    self.outputPipe = pipe
    logger.info("Started daemon", metadata: ["name": .string(configuration.name)])

    guard let signal else { return nil }
    return try await awaitReadiness(signal)
  }

  private func awaitReadiness(_ signal: ReadinessSignal) async throws -> String {
    do {
      return try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
          // The cancellation handler is not optional here. `withThrowingTaskGroup`
          // waits for every child before it returns, and cancelling a task
          // suspended on a continuation does NOT resume it — so without this the
          // group cannot finish until something else happens to resume it, which
          // for a daemon that started fine but never printed a URL means waiting
          // for the process to exit. The timeout would be silently ignored.
          try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
              Task { await self.register(readiness: continuation) }
            }
          } onCancel: {
            Task { await self.abandonReadiness(throwing: CancellationError()) }
          }
        }
        group.addTask {
          try await Task.sleep(for: signal.timeout)
          throw DaemonError.readyTimeout(after: signal.timeout)
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
          throw DaemonError.readyTimeout(after: signal.timeout)
        }
        return value
      }
    } catch {
      // Belt and braces: the cancellation handler above is what actually unblocks the
      // group, and this clears anything it missed.
      abandonReadiness(throwing: error)
      throw error
    }
  }

  private func register(readiness continuation: CheckedContinuation<String, any Error>) {
    // Already signalled while we were getting here.
    if let value = pendingReadyValue {
      pendingReadyValue = nil
      pendingExit = nil
      readiness = nil
      continuation.resume(returning: value)
      return
    }
    // Or already dead. Checked AFTER the value on purpose: a daemon that printed its URL
    // and then died has started successfully, and the crash that follows is the restart
    // path's business rather than a launch failure.
    if let failure = pendingExit {
      pendingExit = nil
      readiness = nil
      continuation.resume(throwing: failure)
      return
    }
    readyContinuation = continuation
  }

  /// Resumes and clears a pending readiness wait.
  private func abandonReadiness(throwing error: any Error) {
    guard let continuation = readyContinuation else { return }
    readyContinuation = nil
    readiness = nil
    continuation.resume(throwing: error)
  }

  /// Folds whatever the pipe readers have captured into this actor's state.
  private func ingestBuffered() {
    ingest(output: pipeBuffer.take())
  }

  private func ingest(output: String) {
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      let text = String(line)
      outputLines.append(text)
      if outputLines.count > Self.retainedLines {
        outputLines.removeFirst(outputLines.count - Self.retainedLines)
      }
      logger.trace(
        "daemon output",
        metadata: [
          "name": .string(configuration.name),
          "line": .string(text),
        ])

      if let signal = readiness, let value = signal.match(text) {
        readiness = nil
        if let continuation = readyContinuation {
          readyContinuation = nil
          continuation.resume(returning: value)
        } else {
          // Nobody is waiting yet. Held rather than dropped — see
          // `pendingReadyValue`.
          pendingReadyValue = value
        }
      }
    }
  }

  private func handleTermination(code: Int32) async {
    process = nil

    // Drain whatever is still in the pipe BEFORE deciding what to report.
    //
    // The readability handler forwards output through a Task, so a process that prints
    // its error and exits immediately can terminate before that Task has run — and the
    // failure is then reported with no output at all. That output is the whole
    // explanation: "ngrok exited with 1" tells a user nothing, while the line above it
    // usually names the actual problem.
    drainRemainingOutput()

    // A process that dies before signalling readiness has failed to start, and its
    // output is the only explanation anyone will get.
    let failure = DaemonError.exitedBeforeReady(
      code: code, output: outputLines.suffix(20).joined(separator: "\n")
    )
    if let continuation = readyContinuation {
      readyContinuation = nil
      readiness = nil
      continuation.resume(throwing: failure)
      return
    }
    // Nobody is waiting YET, but somebody is about to be — `readiness` is set for the
    // whole of a start that asked for one. Held rather than dropped; see `pendingExit`.
    if readiness != nil, !isStopping {
      pendingExit = failure
      return
    }

    guard !isStopping else { return }

    logger.warning(
      "Daemon exited unexpectedly",
      metadata: [
        "name": .string(configuration.name),
        "code": .stringConvertible(code),
      ])
    await onExit(code)
  }

  /// Reads whatever is left in the pipe, synchronously, and folds in anything the
  /// readability handler already took.
  ///
  /// Both halves matter. The pipe may still hold bytes nobody has read; it may also have been
  /// emptied by the handler moments ago, with those bytes sitting in `pipeBuffer` waiting for
  /// a `Task` that has not been scheduled yet. Reading only the pipe reports an empty
  /// explanation roughly one time in eight.
  private func drainRemainingOutput() {
    if let handle = outputPipe?.fileHandleForReading {
      pipeBuffer.absorbRemaining(from: handle)
      // Released HERE, not only in `stop()`. A daemon that exits on its own never goes
      // through `stop()` — that is the whole point of the termination path — so the
      // handler stayed installed for the life of the server, holding a dispatch source
      // and the pipe's read descriptor for a process that no longer exists. A flapping
      // tunnel leaks one of each per restart, ten times over before the restart limit
      // gives up. Sixty early exits in a stress run peaked at 1.1 GB.
      handle.readabilityHandler = nil
    }
    ingest(output: pipeBuffer.take())
    outputPipe = nil
  }

  public func stop() async {
    isStopping = true
    guard let process, process.isRunning else {
      self.process = nil
      return
    }
    let pid = process.processIdentifier

    // SIGTERM to the process itself, deliberately NOT to its process group.
    //
    // Signalling the group is the obvious way to catch a daemon's children, and it is
    // wrong here: `Process` does not put the child in a new group, so it inherits OURS.
    // `kill(-getpgid(pid), …)` would therefore signal the server — and, under the test
    // runner, the test runner. Killing a group we do not own is a far worse failure than
    // leaving one orphan behind.
    //
    // Each of the three tunnel binaries terminates its own children on SIGTERM, which is
    // what makes this sufficient in practice. A daemon that did not would need to be
    // spawned through `posix_spawn` with POSIX_SPAWN_SETPGROUP so it had a group of its
    // own to signal.
    process.terminate()

    for _ in 0..<50 where process.isRunning {
      try? await Task.sleep(for: .milliseconds(100))
    }
    if process.isRunning {
      kill(pid, SIGKILL)
    }

    // Released explicitly, and before the pipe goes out of scope. The handler retains
    // the pipe; leaving it installed keeps a read source alive on a descriptor nobody is
    // going to write to again.
    (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    outputPipe = nil

    self.process = nil
    logger.info("Stopped daemon", metadata: ["name": .string(configuration.name)])
  }

  /// Whether another restart is allowed.
  ///
  /// A crash long after the last one is a fresh problem and starts a fresh count; a burst
  /// of them means the daemon cannot run here and retrying forever is just noise.
  public func shouldRestart(now: ContinuousClock.Instant = .now) -> Bool {
    if let lastExitAt, now - lastExitAt > configuration.restartWindow {
      restartCount = 0
    }
    lastExitAt = now
    restartCount += 1
    return restartCount <= configuration.maximumRestarts
  }

  public func resetRestartCount() {
    restartCount = 0
    lastExitAt = nil
  }
}

extension DaemonError {
  public var code: String {
    switch self {
    case .executableMissing: "daemon.executable_missing"
    case .launchFailed: "daemon.launch_failed"
    case .exitedBeforeReady: "daemon.exited_before_ready"
    case .readyTimeout: "daemon.ready_timeout"
    }
  }

  public var domain: String { "Proxy" }

  public var title: String {
    switch self {
    case .executableMissing: "A required program is missing"
    case .launchFailed, .exitedBeforeReady, .readyTimeout: "A tunnel program would not start"
    }
  }

  public var body: String {
    switch self {
    case .executableMissing(let path):
      "Nothing is installed at \(path). Reinstalling the tool from Integrations fixes this."
    case .launchFailed(let reason):
      reason
    case .exitedBeforeReady(let code, let output):
      // The program's OWN output leads. "exit status 1" names nothing anyone can act on.
      output.isEmpty ? "It exited with status \(code) without printing anything." : output
    case .readyTimeout(let after):
      "It started but was not ready within \(after.components.seconds) seconds."
    }
  }

  public var context: [String: DiagnosticValue] {
    switch self {
    case .executableMissing(let path): ["path": .string(path)]
    case .launchFailed(let reason): ["reason": .string(reason)]
    case .exitedBeforeReady(let code, _): ["exit_code": .int(Int(code))]
    case .readyTimeout(let after): ["seconds": .int(Int(after.components.seconds))]
    }
  }
}
