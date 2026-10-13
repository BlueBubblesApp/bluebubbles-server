//  DaemonProcess
//  One supervisor for the external binaries the tunnels are.
//
//  cloudflared, ngrok, zrok and tailscaled are each a managed executable with the same
//  lifecycle: spawn, scrape its output for a URL or a readiness line, notice it died,
//  restart. That lifecycle is written once here, so the restart policy, the output scraping
//  and the crash handling are the same whichever tunnel is chosen, and "the tunnel process
//  crashed" means one thing for all of them.
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
  /// A gap longer than this resets the restart count: the same distinction the dylib
  /// injector draws between "broken" and "ran for a while and then crashed".
  public let restartWindow: Duration
  /// How long to wait between attempts once `maximumRestarts` is spent.
  ///
  /// Long because the causes that outlast the fast budget do not clear in seconds: an ISP
  /// outage, a lid that woke on a different network, a provider having a bad afternoon.
  ///
  /// Read by `RestartPacer`, not by this type, as `restartDelay` is. Spending the budget
  /// slows the retry down; it does not end it.
  public let dormantRestartDelay: Duration

  public init(
    name: String,
    executablePath: String,
    arguments: [String] = [],
    environment: [String: String] = [:],
    restartDelay: Duration = .seconds(5),
    maximumRestarts: Int = 10,
    restartWindow: Duration = .seconds(300),
    dormantRestartDelay: Duration = .seconds(300)
  ) {
    self.name = name
    self.executablePath = executablePath
    self.arguments = arguments
    self.environment = environment
    self.restartDelay = restartDelay
    self.maximumRestarts = maximumRestarts
    self.restartWindow = restartWindow
    self.dormantRestartDelay = dormantRestartDelay
  }
}

/// Bytes taken off a daemon's pipe but not yet folded into the actor's state.
///
/// This exists because the two readers of that pipe are both OUTSIDE the actor: the
/// readability handler, on a background queue, and the drain at termination, while everything
/// that interprets what they read is inside it. Handing bytes across that boundary through a
/// `Task` loses the race for a process that prints its error and exits immediately: the
/// termination path runs first, finds a pipe the handler has already emptied, and reports the
/// failure with no output at all. That output is the entire diagnosis: "ngrok exited with 1"
/// tells a user nothing, while the line above it names the expired authtoken.
///
/// So the bytes are captured synchronously, under a lock held across the READ as well as the
/// append. Locking only the append would leave the same race in a smaller window: a handler
/// suspended between `availableData` and storing what it read still holds the only copy.
///
/// BYTES, not text. A read boundary falls wherever the pipe happened to be drained, which can
/// be inside a multi-byte character as easily as inside a line; decoding per read would turn
/// the two halves of one character into two replacement characters. The actor decodes each
/// line once it is whole; see `DaemonProcess.ingest(_:)`.
///
/// One per process, never shared between two: see `DaemonProcess.generation`.
private final class PipeBuffer: Sendable {

  private let bytes = Locked(Data())

  /// Takes what is available now. Called from the readability handler.
  func absorbAvailable(from handle: FileHandle) {
    bytes.withLock { bytes in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      bytes.append(data)
    }
  }

  /// Takes whatever is on the pipe right now, without waiting for more.
  ///
  /// Non-blocking, and that is the whole point of doing it by hand rather than through
  /// `FileHandle.read(upToCount:)`.
  ///
  /// A pipe's read end reports EOF only once EVERY writer has closed it, and the daemon's
  /// own children inherit that write end. `stop()` signals the daemon's process group, but a
  /// daemon that exits on its own signals nobody, and a child that left the group is out of
  /// reach either way, so a child can outlive the daemon holding the pipe open, and a
  /// blocking read waits for a writer that is never coming back.
  ///
  /// A blocking read here would wait on the actor: `handleTermination` calls this, so one
  /// orphaned child would freeze the whole `DaemonProcess`, including the reconnect that
  /// brings the tunnel back. Measured with a shell that forks `sleep 20`: twenty seconds to
  /// disconnect blocking, half a second not.
  ///
  /// Reading only what is buffered loses nothing in practice: a process that has exited has
  /// already completed its writes, and anything arriving later is still picked up by the
  /// readability handler.
  func absorbRemaining(from handle: FileHandle) {
    bytes.withLock { bytes in Self.drain(handle, into: &bytes) }
  }

  private static func drain(_ handle: FileHandle, into bytes: inout Data) {
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
      // 0 is EOF: every writer has gone. -1 is an error, including the EAGAIN that a
      // spurious wakeup produces. Both end the drain.
      guard count > 0 else { return }
      bytes.append(contentsOf: buffer[0..<count])
    }
  }

  /// Everything buffered so far, leaving the buffer empty.
  func take() -> Data {
    bytes.withLock { bytes in
      defer { bytes = Data() }
      return bytes
    }
  }
}

public actor DaemonProcess {

  private let configuration: DaemonConfiguration
  private let logger: Logger
  /// Called when the process dies without anyone having asked it to.
  ///
  /// A `var` rather than a `let` so it can be replaced after construction; see
  /// `onTermination(_:)`.
  private var onExit: @Sendable (Int32) async -> Void

  private var process: Process?
  /// Retained so the last of its output can be drained at termination; see
  /// `handleTermination`.
  private var outputPipe: Pipe?
  /// See `PipeBuffer`: bytes are captured off the pipe synchronously and folded in here
  /// afterwards, so a daemon that dies immediately still carries its own explanation.
  /// Replaced on every start, so bytes a previous process left in flight cannot be read as
  /// this one's.
  private var pipeBuffer = PipeBuffer()
  /// Output after the last newline: the start of a line whose end has not been read yet.
  ///
  /// A read returns whatever the pipe holds at that moment, and that boundary has nothing to
  /// do with the daemon's lines. Splitting each read on its own cuts a URL printed across two
  /// reads in half, and the first half matches as a complete line: the tunnel publishes an
  /// address that resolves to nothing. Held here until its newline arrives, and flushed as a
  /// line of its own at EOF, so a daemon's last words are kept even without one.
  private var partialLine = Data()
  /// Which process the callbacks in flight belong to.
  ///
  /// The termination and readability handlers hop onto this actor through a `Task`, so one
  /// can arrive after its process has been stopped and a NEW one started. Unattributed, a
  /// late termination from the old process takes the new one's `process`, removes its pid
  /// from the ledger, releases its pipe and fails its readiness wait: a healthy daemon
  /// orphaned and reported dead. Each handler carries the generation it was installed for,
  /// and anything not from the current one is dropped.
  private var generation = 0
  private var outputLines: [String] = []
  private var readyContinuation: OnceContinuation<String>?
  private var readiness: ReadinessSignal?
  /// A readiness value that arrived before anyone was waiting for it.
  ///
  /// The continuation is registered from a detached task, so there is a window between the
  /// process starting and the waiter being installed. A fast daemon (or a loaded machine)
  /// prints its URL inside that window, and without somewhere to put it the match is
  /// discarded and the wait times out despite the daemon being perfectly healthy.
  private var pendingReadyValue: String?
  /// A TERMINATION that arrived before anyone was waiting for it.
  ///
  /// The exact mirror of `pendingReadyValue`, needed for the same reason: the waiter is
  /// registered from a detached task, so a daemon that fails instantly (a bad authtoken, a
  /// port already forwarded) can be dead before anyone is listening. Dropping that would
  /// leave the caller to wait out the WHOLE readiness timeout and be told the tunnel "did not
  /// report a URL within 60 seconds", when the daemon printed the real reason and exited a
  /// moment after being launched.
  private var pendingExit: DaemonError?
  private var isStopping = false
  private var restartCount = 0
  private var lastExitAt: ContinuousClock.Instant?

  /// Bounded, because a chatty daemon left running for weeks would otherwise grow this
  /// without limit. Recent lines are what a diagnostic report needs; older ones are noise.
  private static let retainedLines = 200

  /// The longest unterminated line held back waiting for its newline. Past this it is taken
  /// as a line as it stands: a daemon writing without newlines must not grow `partialLine`
  /// for as long as it runs.
  static let maximumLineBytes = 64 * 1024

  /// Where this daemon's pid is written for as long as it runs. See `DaemonLedger`.
  private let ledger: DaemonLedger

  /// - Parameter ledger: **No default, deliberately**, for the reason
  ///   `KeychainSecretStore.init(service:)` has none.
  ///
  ///   A default would have to name a file, and the only one to name is the real
  ///   installation's `daemons.json`, so a caller that said nothing would reach it. That is
  ///   not a tidiness problem. `record` and `forget` write the file, and `reapOrphans` reads
  ///   it and sends SIGTERM to every pid in it, so a test suite spawning daemons under such
  ///   a default writes pids into the file a real server reaps from. Observed: `swift test`
  ///   left a modified `daemons.json` in `~/Library/Application Support/bluebubbles-server`.
  public init(
    configuration: DaemonConfiguration,
    logger: Logger = Logger(label: "bluebubbles.proxy.daemon"),
    ledger: DaemonLedger,
    onExit: @escaping @Sendable (Int32) async -> Void = { _ in }
  ) {
    self.configuration = configuration
    self.logger = logger
    self.ledger = ledger
    self.onExit = onExit
  }

  public var isRunning: Bool { process?.isRunning ?? false }
  public var recentOutput: [String] { outputLines }
  /// The generation of the most recent start. For tests; see `generation`.
  var currentGeneration: Int { generation }

  /// Replaces the unexpected-exit handler.
  ///
  /// Settable after construction, rather than only through `init`, because the object that
  /// wants to know is the one that OWNS this process: `BinaryTunnel` stores a
  /// `DaemonProcess`, so a closure capturing the tunnel cannot be passed to the initialiser
  /// of the tunnel's own stored property. The alternative (making the daemon optional and
  /// building it inside `connect()`) spreads that one ordering problem across every method
  /// that touches it.
  public func onTermination(_ handler: @escaping @Sendable (Int32) async -> Void) {
    onExit = handler
  }

  /// Starts the process and waits for its readiness signal.
  ///
  /// Returns whatever the signal extracted: for a tunnel, the public URL it printed.
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
    partialLine.removeAll()
    // A buffer and a generation of this process's own, so nothing a previous run left in
    // flight is reported as this one's. See `generation`.
    generation += 1
    let current = generation
    let buffer = PipeBuffer()
    pipeBuffer = buffer

    let process = Process()
    process.executableURL = URL(fileURLWithPath: configuration.executablePath)
    process.arguments = configuration.arguments
    process.environment = ProcessInfo.processInfo.environment
      .merging(configuration.environment) { _, new in new }

    // No group is set here: `Process` already starts the child as the leader of a group
    // of its own, which is what lets `stop()` end the daemon's children with it. See
    // `signalTree`.
    //
    // Detached from our stdin so a daemon that reads it cannot block on the server's.
    process.standardInput = FileHandle.nullDevice

    let pipe = Pipe()
    process.standardOutput = pipe
    // Merged deliberately: these binaries print their URL to one stream and their errors
    // to the other, and which is which differs between them and between versions.
    process.standardError = pipe

    // The buffer is captured directly rather than reached through `self`: the read has to
    // happen synchronously here, and it has to survive the actor having gone away.
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      buffer.absorbAvailable(from: handle)
      Task { await self?.ingestBuffered(from: buffer, generation: current) }
    }

    process.terminationHandler = { [weak self] finished in
      let code = finished.terminationStatus
      Task { await self?.handleTermination(code: code, generation: current) }
    }

    do {
      try process.run()
    } catch {
      throw DaemonError.launchFailed(reason: String(describing: error))
    }
    self.process = process
    self.outputPipe = pipe
    // On disk before anything else can happen to this process, so a crash between here
    // and the next line still leaves the next start something to find.
    ledger.record(
      name: configuration.name, pid: process.processIdentifier,
      executablePath: configuration.executablePath
    )
    logger.info("Started daemon", metadata: ["daemon": .string(configuration.name)])

    guard let signal else { return nil }
    do {
      return try await awaitReadiness(signal)
    } catch {
      // A daemon that never became ready is stopped before the failure is reported. Left
      // running, it held `process`, so the next `start` returned nil without launching
      // anything, and a tunnel's reconnect loop read that as "nothing to do" and ended:
      // a daemon printing no address, no retries and no notice, for the life of the server.
      await stop()
      throw error
    }
  }

  private func awaitReadiness(_ signal: ReadinessSignal) async throws -> String {
    try await awaitContinuation(
      timeout: signal.timeout,
      timeoutError: { DaemonError.readyTimeout(after: signal.timeout) },
      register: { await self.register(readiness: $0) },
      abandon: { await self.abandonReadiness($0) }
    )
  }

  private func register(readiness waiter: OnceContinuation<String>) {
    // Timed out or cancelled before it got here: the wait is already over, and
    // storing it would keep a dead wait as the one the next line of output resolves.
    guard !waiter.isResolved else { return }
    // Already signalled while we were getting here.
    if let value = pendingReadyValue {
      pendingReadyValue = nil
      pendingExit = nil
      readiness = nil
      waiter.resume(returning: value)
      return
    }
    // Or already dead. Checked AFTER the value on purpose: a daemon that printed its URL
    // and then died has started successfully, and the crash that follows is the restart
    // path's business rather than a launch failure.
    if let failure = pendingExit {
      pendingExit = nil
      readiness = nil
      waiter.resume(throwing: failure)
      return
    }
    readyContinuation = waiter
  }

  /// Ends a readiness wait that finished without an answer: it timed out or was cancelled.
  ///
  /// `readiness` is cleared whether or not the wait was ever stored, so a daemon that dies
  /// after its start gave up takes the ordinary unexpected-exit path rather than being held
  /// as a `pendingExit` for a waiter that no longer exists.
  private func abandonReadiness(_ waiter: OnceContinuation<String>) {
    if readyContinuation === waiter { readyContinuation = nil }
    readiness = nil
  }

  /// Folds whatever the pipe readers have captured into this actor's state, unless it came
  /// from a process that is no longer this daemon's. See `generation`.
  private func ingestBuffered(from buffer: PipeBuffer, generation: Int) {
    guard generation == self.generation else { return }
    ingest(buffer.take())
  }

  /// Appends bytes read from the pipe and consumes every line they complete. What follows
  /// the last newline waits in `partialLine` for the rest of its line.
  private func ingest(_ bytes: Data) {
    partialLine.append(bytes)
    while let newline = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
      consume(line: partialLine[partialLine.startIndex..<newline])
      partialLine = Data(partialLine[partialLine.index(after: newline)...])
    }
    if partialLine.count > Self.maximumLineBytes {
      flushPartialLine()
    }
  }

  /// Takes whatever is waiting for a newline as a line in its own right: at EOF, where no
  /// newline is coming, or once it has grown past `maximumLineBytes`.
  private func flushPartialLine() {
    let line = partialLine
    partialLine = Data()
    consume(line: line)
  }

  /// One whole line of output. Empty lines are skipped.
  private func consume(line bytes: Data) {
    guard !bytes.isEmpty else { return }
    let text = String(decoding: bytes, as: UTF8.self)
    outputLines.append(text)
    if outputLines.count > Self.retainedLines {
      outputLines.removeFirst(outputLines.count - Self.retainedLines)
    }
    logger.trace(
      "daemon output",
      metadata: [
        "daemon": .string(configuration.name),
        "line": .string(text),
      ])

    if let signal = readiness, let value = signal.match(text) {
      readiness = nil
      if let continuation = readyContinuation {
        readyContinuation = nil
        continuation.resume(returning: value)
      } else {
        // Nobody is waiting yet. Held rather than dropped; see `pendingReadyValue`.
        pendingReadyValue = value
      }
    }
  }

  /// The process started as `generation` has ended.
  ///
  /// Internal rather than private so a test can deliver a termination late: the ordering
  /// the generation check exists for, and one a real process cannot be made to produce on
  /// demand.
  func handleTermination(code: Int32, generation: Int) async {
    // From a process this daemon has already stopped and possibly replaced. Everything
    // below acts on the CURRENT process's state, so a late callback is dropped here rather
    // than allowed to tear down its successor. See `generation`.
    guard generation == self.generation, let process else { return }
    ledger.forget(pid: process.processIdentifier)
    self.process = nil

    // Drain whatever is still in the pipe BEFORE deciding what to report.
    //
    // The readability handler forwards output through a Task, so a process that prints
    // its error and exits immediately can terminate before that Task has run, and the
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
    // Nobody is waiting YET, but somebody is about to be: `readiness` is set for the
    // whole of a start that asked for one. Held rather than dropped; see `pendingExit`.
    if readiness != nil, !isStopping {
      pendingExit = failure
      return
    }

    guard !isStopping else { return }

    logger.warning(
      "Daemon exited unexpectedly",
      metadata: [
        "daemon": .string(configuration.name),
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
      // through `stop()`, so without this the handler would stay installed for the life
      // of the server, holding a dispatch source and the pipe's read descriptor for a
      // process that no longer exists: one of each per restart of a flapping tunnel.
      // Measured: sixty early exits in a stress run peaked at 1.1 GB.
      handle.readabilityHandler = nil
    }
    ingest(pipeBuffer.take())
    // EOF: nothing will complete the line now, so it is taken as it stands.
    flushPartialLine()
    outputPipe = nil
  }

  public func stop() async {
    isStopping = true
    guard let process, process.isRunning else {
      if let pid = self.process?.processIdentifier { ledger.forget(pid: pid) }
      self.process = nil
      // Exited on its own, with its termination not yet handled. Clearing `process` makes
      // that termination a no-op when it lands (see `handleTermination`), so its pipe is
      // released here instead, or the read source would outlive it.
      drainRemainingOutput()
      return
    }
    let pid = process.processIdentifier
    defer { ledger.forget(pid: pid) }

    // The daemon's whole tree, not just the daemon: see `signalTree`. Only while it is
    // still running, because only then is its pid, and so its group id, certainly ours.
    Self.signalTree(SIGTERM, pid: pid)

    // Up to five seconds to go quietly. A cancelled stop escalates at once rather than
    // spinning out the same fifty checks without sleeping: the daemon is going either way.
    _ = try? await poll(.every(.milliseconds(100), attempts: 50)) { _ in
      process.isRunning ? nil : true
    }
    if process.isRunning {
      Self.signalTree(SIGKILL, pid: pid)
    }

    // Released explicitly, and before the pipe goes out of scope. The handler retains
    // the pipe; leaving it installed keeps a read source alive on a descriptor nobody is
    // going to write to again.
    (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    outputPipe = nil

    self.process = nil
    logger.info("Stopped daemon", metadata: ["daemon": .string(configuration.name)])
  }

  /// Signals the daemon's process group when the daemon leads one of its own, and the daemon
  /// alone otherwise.
  ///
  /// `Process` starts its child as the leader of a NEW group (the group id is the child's
  /// pid; measured on macOS 27, and pinned by a test), so the group is the daemon plus
  /// whatever it spawned that did not leave it: cloudflared's helpers, the child of a shell
  /// wrapper. Signalling the daemon alone leaves those running, holding the output pipe open
  /// and, for a tunnel, a session we believe closed.
  ///
  /// Checked on every call rather than assumed, because the one unacceptable outcome is
  /// signalling a group this process is IN: that is the server, and under the test runner
  /// the test runner. A child that shares our group gets its own pid signalled and nothing
  /// more, which costs at worst an orphan.
  static func signalTree(_ signal: Int32, pid: pid_t) {
    if leadsOwnGroup(pid) {
      killpg(pid, signal)
    } else {
      kill(pid, signal)
    }
  }

  /// Whether `pid` leads a process group that is not this process's own.
  static func leadsOwnGroup(_ pid: pid_t) -> Bool {
    let group = getpgid(pid)
    return group == pid && group != getpgrp()
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
