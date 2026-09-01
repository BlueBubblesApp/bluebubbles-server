//  Subprocess
//  One way to run a child process, because there were nine.
//
//  Every module that shelled out built its own `Process()` and re-decided the same four
//  questions, independently and differently:
//
//    - **Draining.** A pipe holds 64 KB. Calling `waitUntilExit()` before reading it
//      deadlocks the moment a child writes more than that — the child blocks on a full pipe,
//      the parent blocks waiting for the child. Every site got the ordering right, but each
//      one rediscovered it and re-explained it in a comment.
//    - **Timeouts.** `SystemInfo.timeSync` had one. `ToolInstaller.probeVersion` had one.
//      `Unpacking.run` had none, so an unpacker that decided to prompt hung the install
//      with no way out. `Permissions.csrutilFallback` had none either.
//    - **stdin.** Only `Unpacking.run` detached it, having been taught by `unzip`, which
//      prompts when an archive contains a name that already exists. Every other site would
//      have hung the same way given a child that asked a question.
//    - **Where the wait happens.** `waitUntilExit()` blocks. Called from an async function
//      it parks a cooperative-pool thread, which is a thread the rest of the server needs.
//      `SystemInfoProvider` knew this and wrapped its call in `Task.detached` with a comment
//      explaining why; nothing else could reuse that knowledge, and
//      `Permissions.csrutilFallback` — an `async` function — blocked inline.
//
//  None of that is per-site knowledge. It is one correct way to run a command, and this is
//  it. `ZrokEnvironment.run` had already worked most of it out; this is that implementation,
//  generalised, minus the busy-wait loops two of the others used.
//
//  NOT for long-lived processes. A supervised daemon needs streaming output, readiness
//  signals, its own process group and a termination handler — see `BBProxy.DaemonProcess`,
//  which is a different problem and stays its own type.

import Foundation

public enum Subprocess {

  // MARK: - What came back

  public struct Result: Sendable {
    /// The child's exit status. Zero is success by convention; a few of the binaries we
    /// call do not honour it, which is why this is reported rather than interpreted.
    public let status: Int32
    /// Whatever was captured, per the `Output` mode. Empty under `.discarded`.
    public let output: Data

    public var succeeded: Bool { status == 0 }
    public var text: String { String(decoding: output, as: UTF8.self) }
    /// The usual want: output as text, without the trailing newline every CLI adds.
    public var trimmedText: String {
      text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  /// What to do with the child's two output streams.
  public enum Output: Sendable {
    /// Both into one stream.
    ///
    /// The right default for tools whose choice of stream is not stable: zrok, tar and
    /// unzip all put some of their answer on stderr and some on stdout, and which is which
    /// has moved between versions.
    case merged
    /// stdout captured, stderr discarded. For a command whose stderr is noise we have no
    /// use for — `csrutil`, `lipo`, `sdef`.
    case standardOutputOnly
    /// Both discarded. For a launch whose output would only interleave into our log with
    /// no context; the caller finds out whether it worked some other way.
    case discarded
  }

  public enum Failure: BBError, Equatable {
    case launchFailed(executable: String, reason: String)
    case timedOut(executable: String, seconds: Double)
  }

  // MARK: - Running one

  /// Runs a command to completion and returns what it said.
  ///
  /// - Parameter timeout: Required, with no default, deliberately. Three of the call sites
  ///   this replaced had no timeout at all, and in each case that was an oversight rather
  ///   than a decision — a command with no deadline is one that can hang the caller
  ///   forever. Making it a parameter with no default forces the decision to be made once,
  ///   visibly, per call site.
  /// - Throws: `Failure.launchFailed` if the binary could not be started at all — a missing
  ///   file, or the wrong architecture, which `posix_spawn` reports here rather than as a
  ///   non-zero exit. `Failure.timedOut` if it had to be killed.
  public static func run(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String] = [:],
    output: Output = .merged,
    timeout: Duration
  ) async throws -> Result {
    let (process, drain) = try prepare(
      executable, arguments, environment: environment, output: output
    )

    // The child is awaited through its termination handler rather than by blocking a
    // thread on `waitUntilExit()`. Nothing is parked: the handler fires on a Foundation
    // queue when the process ends, and resumes us there.
    //
    // The handler is installed BEFORE `run()`, synchronously, and that is not a style
    // preference. Assigning it from inside a `Task` — which is where it naturally wants to
    // go, next to the continuation it resumes — loses the race against a command that
    // exits quickly: Foundation finds a nil handler, calls nothing, and the continuation
    // is installed afterwards and resumed by nobody. `echo hello` is fast enough to hit
    // that essentially always. `ExitWaiter` is what lets the signal arrive before the wait.
    let exited = ExitWaiter()
    process.terminationHandler = { _ in exited.signal() }

    do {
      try process.run()
      drain.didLaunch()
    } catch {
      drain.finish(waitingForEOF: false)
      throw Failure.launchFailed(
        executable: executable, reason: String(describing: error)
      )
    }

    // The deadline does not cancel the wait — it KILLS THE CHILD, which makes the wait
    // finish on its own. That ordering is the load-bearing part: `terminationHandler` is
    // the only thing that resumes the continuation above, so a timeout that merely
    // abandoned the wait would leave it suspended forever.
    let killed = Flag()
    let watchdog = Task {
      try await Task.sleep(for: timeout)
      guard process.isRunning else { return }
      killed.set()
      process.terminate()
    }

    await exited.wait()
    watchdog.cancel()

    let collected = drain.finish()

    if killed.isSet {
      throw Failure.timedOut(executable: executable, seconds: timeout.seconds)
    }
    return Result(status: process.terminationStatus, output: collected)
  }

  /// The blocking form, for callers that genuinely cannot suspend.
  ///
  /// There is one shape that needs it: a DEFAULT ARGUMENT, which cannot be `async`.
  /// `MessagesScripts.source(services:)` defaults to `supportedServices()`, which reads the
  /// Messages scripting dictionary with `sdef`.
  ///
  /// Do not reach for this anywhere else. It blocks the calling thread for as long as the
  /// command runs, and from an async context that is a cooperative-pool thread the rest of
  /// the server needs. Same warning, and the same reason, as
  /// `AppDatabase.writeSynchronously`.
  public static func runSynchronously(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String] = [:],
    output: Output = .merged,
    timeout: Duration
  ) throws -> Result {
    let (process, drain) = try prepare(
      executable, arguments, environment: environment, output: output
    )

    // Signalled by the termination handler rather than by `waitUntilExit()`, because a
    // semaphore can be waited on WITH A DEADLINE and `waitUntilExit` cannot.
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }

    do {
      try process.run()
      drain.didLaunch()
    } catch {
      drain.finish(waitingForEOF: false)
      throw Failure.launchFailed(
        executable: executable, reason: String(describing: error)
      )
    }

    if finished.wait(timeout: .now() + timeout.seconds) == .timedOut {
      process.terminate()
      // A short grace period so the handler can fire and the drain can be closed on a
      // process that is actually gone, rather than tearing down around a live child.
      _ = finished.wait(timeout: .now() + 2)
      drain.finish()
      throw Failure.timedOut(executable: executable, seconds: timeout.seconds)
    }

    return Result(status: process.terminationStatus, output: drain.finish())
  }

  /// Starts a command and does NOT wait for it.
  ///
  /// For a launch whose result is established some other way — `DylibInjector` starts an
  /// application with an inserted dylib and then confirms the injection by whether the
  /// helper connects, which is the only evidence that actually means anything.
  public static func launch(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String] = [:]
  ) throws {
    let (process, _) = try prepare(
      executable, arguments, environment: environment, output: .discarded
    )
    do {
      try process.run()
    } catch {
      throw Failure.launchFailed(
        executable: executable, reason: String(describing: error)
      )
    }
  }

  // MARK: - Shared setup

  /// Builds the process and starts draining it, without running it.
  ///
  /// The drain is attached BEFORE `run()` in every path above, which is what makes the
  /// 64 KB pipe limit a non-issue: output is absorbed as it arrives rather than read after
  /// the child has finished, so a chatty command cannot fill the pipe and block itself.
  private static func prepare(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String],
    output: Output
  ) throws -> (Process, Drain) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if !environment.isEmpty {
      process.environment = ProcessInfo.processInfo.environment
        .merging(environment) { _, new in new }
    }

    // ALWAYS detached, with no way to ask for otherwise.
    //
    // Nothing this server runs should ever read our stdin, and a child that decides to
    // prompt would otherwise wait on a terminal nobody is watching — forever, if the
    // caller also forgot a timeout. `unzip` does exactly this when an archive contains a
    // name that already exists.
    process.standardInput = FileHandle.nullDevice

    switch output {
    case .discarded:
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      return (process, Drain(pipe: nil))
    case .standardOutputOnly:
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      return (process, Drain(pipe: pipe))
    case .merged:
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      return (process, Drain(pipe: pipe))
    }
  }

  /// Absorbs a pipe as it fills.
  ///
  /// Two things here are load-bearing, and getting either wrong hangs the caller forever
  /// rather than failing:
  ///
  ///   1. **Our copy of the write end is closed once the child is running.** `Pipe` holds
  ///      both ends, and while this process holds a writable one the reader has a live
  ///      writer and can never see EOF — we would be waiting on ourselves. The child dup'd
  ///      its own descriptor during spawn, so closing ours does not affect it.
  ///   2. **EOF is detected in the readability handler, not by `readToEnd()`.** An empty
  ///      `availableData` IS the end-of-file signal. `readToEnd()` looks like the tidy way
  ///      to collect the remainder and is the trap: it blocks until every write end is
  ///      closed, which is the same condition, so it deadlocks in exactly the case it was
  ///      added to handle. `ZrokEnvironment.run` avoided this by never calling it.
  ///
  /// `@unchecked Sendable` because the handler runs on a queue Foundation owns while the
  /// caller reads the result on its own; the `NSLock` is what makes that safe.
  private final class Drain: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let reachedEOF = DispatchSemaphore(value: 0)
    private let pipe: Pipe?

    init(pipe: Pipe?) {
      self.pipe = pipe
      pipe?.fileHandleForReading.readabilityHandler = { [self] handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else {
          // Every writer is gone. Detach first so this cannot be re-entered, then
          // release anyone waiting in `finish`.
          handle.readabilityHandler = nil
          reachedEOF.signal()
          return
        }
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
      }
    }

    /// Drops our write end so the reader can reach EOF.
    ///
    /// Called immediately after `run()` succeeds, and only then: before the spawn there is
    /// nothing to close, and closing early would hand the child a dead descriptor.
    func didLaunch() {
      guard let pipe else { return }
      try? pipe.fileHandleForWriting.close()
    }

    /// Detaches and returns everything.
    ///
    /// - Parameter waitingForEOF: whether to give the pipe a moment to finish draining.
    ///   True once the child has exited, so output written just before it died is not
    ///   lost; false when the spawn itself failed and there is nothing to wait for. The
    ///   wait is BOUNDED — a grandchild holding the pipe open would otherwise reproduce
    ///   the very hang this type exists to avoid, so it degrades to returning what we have.
    @discardableResult
    func finish(waitingForEOF: Bool = true) -> Data {
      guard let pipe else { return Data() }
      if waitingForEOF {
        _ = reachedEOF.wait(timeout: .now() + 2)
      }
      pipe.fileHandleForReading.readabilityHandler = nil
      lock.lock()
      defer { lock.unlock() }
      return buffer
    }
  }

  /// Bridges `terminationHandler` — which fires once, on a queue Foundation owns — to one
  /// `await`, and tolerates the signal arriving BEFORE anyone waits.
  ///
  /// That ordering is the normal case, not the edge case: the handler is installed before
  /// the process is started, so a short command can be finished before the caller reaches
  /// `wait()`. A bare `withCheckedContinuation` cannot express this — the continuation does
  /// not exist yet at the moment it would need to be resumed.
  private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var hasExited = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
      lock.lock()
      if hasExited {
        lock.unlock()
        return
      }
      hasExited = true
      let waiting = continuation
      continuation = nil
      lock.unlock()
      // Resumed OUTSIDE the lock: the continuation runs caller code, and holding a lock
      // across it invites a deadlock against anything that calls back in here.
      waiting?.resume()
    }

    func wait() async {
      await withCheckedContinuation { continuation in
        lock.lock()
        if hasExited {
          lock.unlock()
          continuation.resume()
          return
        }
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  /// A one-way flag, set from a task and read after it.
  private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() {
      lock.lock()
      value = true
      lock.unlock()
    }
    var isSet: Bool {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }
}

extension Subprocess.Failure {
  public var code: String {
    switch self {
    case .launchFailed: "subprocess.launch_failed"
    case .timedOut: "subprocess.timed_out"
    }
  }

  public var domain: String { "Subprocess" }

  /// Not user-facing on its own. Every caller wraps this in an error of its own that can
  /// say what the command was FOR — "the tunnel binary could not be started" means
  /// something to a person; "/usr/bin/sntp exited 1" does not.
  public var title: String { "A command could not be run" }

  public var body: String {
    switch self {
    case .launchFailed(let executable, let reason):
      "\(executable) could not be started: \(reason)"
    case .timedOut(let executable, let seconds):
      "\(executable) did not finish within \(Int(seconds)) seconds and was stopped."
    }
  }
}
