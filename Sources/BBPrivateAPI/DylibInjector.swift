//  DylibInjector
//  Restarts Messages.app with the helper dylib loaded.
//
//  The mechanism is forced by macOS rather than chosen: kill the parent app, relaunch it with
//  `DYLD_INSERT_LIBRARIES` set, and wait for the helper inside it to announce itself. The
//  retry policy is explicit.
//
//  Preconditions this cannot paper over
//  ------------------------------------
//  - **SIP must be disabled.** Library validation otherwise refuses to load an unsigned dylib
//    into an Apple-signed process, and Messages starts fine without it.
//  - **The dylib must match the slice Messages runs.** On Apple Silicon that is arm64e, not
//    arm64. dyld does not fail loudly here: it skips the inserted library, prints one line to
//    stderr, and lets Messages start normally. The symptom is a helper that never connects
//    and no error anywhere. This is why the shipped `BlueBubblesHelper.dylib` is universal
//    with an arm64e slice, and why `verify()` checks the slice before trying.
//
//  Both were learned from the observation probe; see docs/OBSERVATION_LADDER.md.
//
//  See `.claude/docs/private-api.md`.

import AppKit
import BBCore
import BBDiagnostics
import Darwin
import Foundation
import Logging

public enum DylibInjectionError: BBError, Equatable {
  case dylibMissing(path: String)
  case parentApplicationMissing(name: String)
  /// The dylib has no slice matching the architecture the parent runs.
  case architectureMismatch(dylib: [String], parent: [String])
  /// Relaunched, but the helper never announced itself.
  case helperNeverRegistered(attempts: Int)
}

/// How aggressively to retry a failed injection.
public struct InjectionPolicy: Sendable, Equatable {
  /// Consecutive failures before giving up.
  public let maximumConsecutiveFailures: Int
  /// A gap longer than this resets the failure count, so a helper that ran for a while and
  /// then crashed is treated as a fresh problem rather than a continuation of an old one.
  public let failureWindow: Duration
  /// How long to wait for the `ping` after relaunching.
  public let registrationTimeout: Duration
  /// Pause between quitting the app and relaunching it.
  ///
  /// Belt and braces: `terminate` already waits for the process to exit, but relaunching
  /// the instant it does occasionally gets the old process back without the dylib, which
  /// looks exactly like a failed injection. Configurable so tests need not sit through it.
  public let relaunchDelay: Duration

  public init(
    maximumConsecutiveFailures: Int = 5,
    failureWindow: Duration = .seconds(15),
    registrationTimeout: Duration = .seconds(30),
    relaunchDelay: Duration = .seconds(1)
  ) {
    self.maximumConsecutiveFailures = maximumConsecutiveFailures
    self.failureWindow = failureWindow
    self.registrationTimeout = registrationTimeout
    self.relaunchDelay = relaunchDelay
  }

  /// The current server's numbers: five failures, with a fifteen-second reset window.
  public static let legacy = InjectionPolicy()
}

public actor DylibInjector {

  public struct Target: Sendable {
    /// Application name as it appears in `/Applications`, such as `Messages`.
    public let applicationName: String
    /// Bundle identifier the helper reports in its `ping`, such as `com.apple.MobileSMS`.
    public let bundleIdentifier: String
    public let dylibPath: String
    /// Extra variables set on the relaunched app, alongside `DYLD_INSERT_LIBRARIES`.
    ///
    /// The injection environment is the only channel the helper can read at LOAD time. It is
    /// a separate process inside somebody else's sandbox, so a setting it needs before it has
    /// connected to the socket has to arrive this way. `DYLD_INSERT_LIBRARIES` is set here
    /// too and always wins; a caller cannot accidentally unset the injection itself.
    public let environment: [String: String]

    public init(
      applicationName: String,
      bundleIdentifier: String,
      dylibPath: String,
      environment: [String: String] = [:]
    ) {
      self.applicationName = applicationName
      self.bundleIdentifier = bundleIdentifier
      self.dylibPath = dylibPath
      self.environment = environment
    }

    /// Both locations are checked because an app installed before Catalina lives in
    /// `/Applications` while a system one lives under `/System/Applications`.
    public var executablePath: String? {
      let candidates = [
        "/System/Applications/\(applicationName).app/Contents/MacOS/\(applicationName)",
        "/Applications/\(applicationName).app/Contents/MacOS/\(applicationName)",
      ]
      return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
  }

  private let target: Target
  private let policy: InjectionPolicy
  private let logger: Logger
  private let processRunner: any ProcessRunning

  private var consecutiveFailures = 0
  private var lastFailureAt: ContinuousClock.Instant?
  private var isInjecting = false
  private var isStopping = false

  public init(
    target: Target,
    policy: InjectionPolicy = .legacy,
    processRunner: (any ProcessRunning)? = nil,
    logger: Logger = Logger(label: "bluebubbles.privateapi.injector")
  ) {
    self.target = target
    self.policy = policy
    self.processRunner = processRunner ?? SystemProcessRunner()
    self.logger = logger
  }

  // MARK: - Preflight

  /// Everything checkable before touching the user's running Messages.
  ///
  /// Deliberately separate from `inject`: quitting someone's Messages only to discover the
  /// dylib is the wrong architecture is a bad trade, and these answers also drive what the
  /// UI can tell them.
  ///
  /// - Parameter hostIsAppleSilicon: which processor this Mac has, which decides the slice the
  ///   parent runs. A parameter so a test can ask both questions on one machine.
  public func verify(hostIsAppleSilicon: Bool = DylibInjector.hostIsAppleSilicon) throws {
    guard FileManager.default.fileExists(atPath: target.dylibPath) else {
      throw DylibInjectionError.dylibMissing(path: target.dylibPath)
    }
    guard let executablePath = target.executablePath else {
      throw DylibInjectionError.parentApplicationMissing(name: target.applicationName)
    }

    let dylibArchitectures = processRunner.architectures(of: target.dylibPath)
    let parentArchitectures = processRunner.architectures(of: executablePath)

    // STILL NOT FATAL when the slices cannot be read, and that is deliberate rather than an
    // oversight. Making it fatal was tried and reverted: the reader's fallback shells out to
    // `/usr/bin/lipo`, which on a Mac with no Command Line Tools installed does not run at
    // all, so a hard stop here would disable the Private API for most users in order to
    // enforce a check that could not run. What makes that acceptable is that the reader no
    // longer NEEDS `lipo`: it parses the Mach-O header itself (`MachOArchitectures`), which
    // works on any Mac and cannot fail for want of developer tools.
    //
    // An empty list means "could not tell", never "no slices in common".
    guard !dylibArchitectures.isEmpty, !parentArchitectures.isEmpty,
      let running = Self.runningSlice(of: parentArchitectures, appleSilicon: hostIsAppleSilicon)
    else { return }

    // The slice the parent RUNS, not any slice the two share. A plain `arm64 x86_64` dylib
    // shares `x86_64` with Messages' `x86_64 arm64e`, so "any shared slice" passed it on
    // Apple Silicon, where Messages runs arm64e and dyld silently declines the insert.
    guard dylibArchitectures.contains(running) else {
      throw DylibInjectionError.architectureMismatch(
        dylib: dylibArchitectures, parent: parentArchitectures
      )
    }
  }

  /// The slice a process launched from `parent` runs on this Mac.
  ///
  /// On Apple silicon, the most capable ARM slice the binary has: arm64e for a platform
  /// binary such as Messages, arm64 otherwise, and x86_64 only for a binary with no ARM
  /// slice at all, under Rosetta. On Intel, x86_64. Nil when the binary has no slice this
  /// Mac can run, which the launch itself will report.
  static func runningSlice(of parent: [String], appleSilicon: Bool) -> String? {
    let preference = appleSilicon ? ["arm64e", "arm64", "x86_64"] : ["x86_64"]
    return preference.first(where: parent.contains)
  }

  /// Whether this Mac's processor is Apple silicon, whichever slice this process runs.
  ///
  /// The hardware rather than `#if arch(arm64)`: a server running its x86_64 slice under
  /// Rosetta still injects into a Messages that runs arm64e.
  public static var hostIsAppleSilicon: Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
  }

  // MARK: - Injection

  /// Quits the parent app and relaunches it with the dylib inserted.
  ///
  /// - Parameter waitForRegistration: Awaited to learn whether the helper actually came up.
  ///   The injector cannot tell on its own: Messages launching proves nothing, because dyld
  ///   carries on without a library it declined.
  public func inject(
    waitForRegistration: @Sendable @escaping (Duration) async -> Bool
  ) async throws {
    guard !isInjecting else { return }
    isInjecting = true
    defer { isInjecting = false }

    try verify()
    guard let executablePath = target.executablePath else {
      throw DylibInjectionError.parentApplicationMissing(name: target.applicationName)
    }

    consecutiveFailures = 0
    lastFailureAt = nil
    // Re-armed here rather than cleared by `stop()`. A stop that un-stops itself is not a
    // stop: the retry loop sleeps between attempts, so if the flag were cleared as soon
    // as the app had been killed, the loop would wake to find it false and keep going
    // forever. Shutdown is sticky until someone deliberately injects again.
    isStopping = false

    while !isStopping, consecutiveFailures < policy.maximumConsecutiveFailures {
      do {
        logger.debug(
          "Restarting the parent application with the helper inserted",
          metadata: [
            "app": .string(target.applicationName)
          ])
        await processRunner.terminate(applicationNamed: target.applicationName)
        try await Task.sleep(for: policy.relaunchDelay)
        if isStopping { return }

        try processRunner.launch(
          executable: executablePath,
          environment: target.environment.merging(
            ["DYLD_INSERT_LIBRARIES": target.dylibPath],
            uniquingKeysWith: { _, injected in injected }
          )
        )

        if await waitForRegistration(policy.registrationTimeout) {
          logger.info(
            "Helper registered",
            metadata: [
              "process": .string(target.bundleIdentifier)
            ])
          consecutiveFailures = 0
          return
        }
        recordFailure(reason: "the helper never registered")
      } catch {
        recordFailure(reason: String(describing: error))
      }
    }

    guard !isStopping else { return }
    throw DylibInjectionError.helperNeverRegistered(attempts: consecutiveFailures)
  }

  /// A failure far enough after the previous one starts a fresh count.
  ///
  /// The distinction being drawn: five instant failures means injection is broken and
  /// retrying is pointless. One failure every few minutes means the helper ran and then
  /// crashed, which is worth restarting indefinitely.
  private func recordFailure(reason: String) {
    let now = ContinuousClock.now
    if let lastFailureAt, now - lastFailureAt > policy.failureWindow {
      consecutiveFailures = 0
    }
    consecutiveFailures += 1
    lastFailureAt = now

    let level: Logger.Level =
      consecutiveFailures >= policy.maximumConsecutiveFailures ? .error : .debug
    logger.log(
      level: level, "Helper injection failed",
      metadata: [
        "reason": .string(Redaction.identifiers(in: reason)),
        "attempt": .stringConvertible(consecutiveFailures),
        "limit": .stringConvertible(policy.maximumConsecutiveFailures),
      ])
  }

  /// Stops retrying and quits the parent application.
  ///
  /// The stopping flag STAYS set; see `inject`, which clears it when a new injection
  /// starts. Clearing it here would let an in-flight retry loop resume after shutdown.
  public func stop() async {
    isStopping = true
    await processRunner.terminate(applicationNamed: target.applicationName)
  }

  public var failureCount: Int { consecutiveFailures }
}

// MARK: - Process control

/// The bits of the OS the injector touches, behind a protocol so it can be tested without
/// quitting anyone's Messages.
public protocol ProcessRunning: Sendable {
  func terminate(applicationNamed name: String) async
  func launch(executable: String, environment: [String: String]) throws
  /// Mach-O slices in a binary, such as `["x86_64", "arm64e"]`. Empty when unreadable.
  func architectures(of path: String) -> [String]
}

public struct SystemProcessRunner: ProcessRunning {

  public init() {}

  public func terminate(applicationNamed name: String) async {
    // Ask politely first: a Quit Apple Event lets Messages finish writing chat.db, and
    // force-killing it mid-write is how a database ends up corrupt.
    let running = NSWorkspace.shared.runningApplications.filter {
      $0.localizedName == name || $0.bundleURL?.deletingPathExtension().lastPathComponent == name
    }
    for application in running {
      application.terminate()
    }

    // PROGRESS IS MEASURED BY PROCESS PATH, NOT BY NSWorkspace.
    //
    // `NSWorkspace.runningApplications` did not see apps this server had launched itself
    // from a headless process: the polite pass matched nothing, the wait loop concluded
    // the app had exited, and the relaunch produced a SECOND copy. Measured: two
    // Messages processes running at once, both writing chat.db, while the endpoint
    // reported a successful restart. `proc_pidpath` sees every process regardless of how
    // it was started, so it is the authority here.
    guard let executablePath = Self.executablePath(forApplicationNamed: name) else { return }

    // Each wait ENDS on cancellation, and so does the escalation: a caller that has gone is
    // not killing Messages. Slept with `try?`, a cancelled wait returned at once, the loop
    // ran out in microseconds and the next line sent SIGKILL to an app mid-write.
    func exited(within attempts: Int, every interval: Duration) async throws -> Bool {
      try await poll(.every(interval, attempts: attempts)) { _ in
        Self.processIdentifiers(running: executablePath).isEmpty ? true : nil
      } != nil
    }
    do {
      if try await exited(within: 20, every: .milliseconds(500)) { return }
      // Still there. Escalate, and keep escalating rather than assuming a signal landed.
      for pid in Self.processIdentifiers(running: executablePath) { kill(pid, SIGTERM) }
      if try await exited(within: 8, every: .milliseconds(250)) { return }
    } catch {
      return
    }
    for pid in Self.processIdentifiers(running: executablePath) { kill(pid, SIGKILL) }
  }

  /// Both locations, matching `Target.executablePath`: an app installed before Catalina
  /// lives in `/Applications` while a system one lives under `/System/Applications`.
  static func executablePath(forApplicationNamed name: String) -> String? {
    [
      "/System/Applications/\(name).app/Contents/MacOS/\(name)",
      "/Applications/\(name).app/Contents/MacOS/\(name)",
    ].first { FileManager.default.fileExists(atPath: $0) }
  }

  /// Every live process running exactly this executable.
  static func processIdentifiers(running executablePath: String) -> [pid_t] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    // Headroom: processes can appear between sizing the buffer and filling it.
    var identifiers = [pid_t](repeating: 0, count: Int(capacity) + 64)
    let byteCount = Int32(identifiers.count * MemoryLayout<pid_t>.size)
    let filled = proc_listallpids(&identifiers, byteCount)
    guard filled > 0 else { return [] }

    var matches: [pid_t] = []
    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a macro, so it does not import.
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for identifier in identifiers.prefix(Int(filled)) where identifier > 0 {
      guard proc_pidpath(identifier, &path, UInt32(path.count)) > 0 else { continue }
      if Self.decodeCString(path) == executablePath { matches.append(identifier) }
    }
    return matches
  }

  public func launch(executable: String, environment: [String: String]) throws {
    // Output discarded on purpose: dyld's complaints go to stderr, and inheriting the
    // server's would interleave them into our log with no context. The injector reports
    // what it knows through `verify()` instead.
    try Subprocess.launch(executable, environment: environment)
  }

  /// Synchronous deliberately: `verify()` is not async, and `ProcessRunning` is the seam
  /// the tests inject a fake through; making one method async would change both, for a
  /// `lipo` call that answers in milliseconds.
  public func architectures(of path: String) -> [String] {
    // The binary's own header, not `/usr/bin/lipo`.
    //
    // `lipo` is not part of a stock macOS: without Command Line Tools it does not run, so
    // this check silently reported "no slices" on exactly the machines most likely to be
    // carrying a mismatched build, and the guard did nothing. Reading the header works
    // everywhere, costs no subprocess, and is testable against bytes rather than against
    // whether a developer tool happens to be installed. See `MachOArchitectures`.
    let slices = MachOArchitectures.read(contentsOf: path)
    guard slices.isEmpty else { return slices }

    // Fallback for anything the parser does not recognise, so an unusual binary degrades to
    // the old behaviour rather than to "unreadable". Still not fatal when it fails; see
    // `verify()`.
    guard
      let result = try? Subprocess.runSynchronously(
        "/usr/bin/lipo", ["-archs", path],
        output: .standardOutputOnly, timeout: .seconds(15)
      ),
      result.succeeded
    else { return [] }
    // `lipo -archs` prints space-separated slice names and pads them: splitting on a literal
    // " " leaves empty strings from a double space or a trailing newline, and an empty name
    // is not a slice.
    return result.trimmedText
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }

  /// A NUL-terminated C buffer as a String.
  ///
  /// `String(cString:)` on a `[CChar]` is deprecated because it scans past the array's
  /// own bounds for the terminator. Truncating at the NUL and decoding the prefix is the
  /// documented replacement.
  static func decodeCString(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}

extension DylibInjectionError {
  public var code: String {
    switch self {
    case .dylibMissing: "private_api.dylib_missing"
    case .parentApplicationMissing: "private_api.parent_application_missing"
    case .architectureMismatch: "private_api.architecture_mismatch"
    case .helperNeverRegistered: "private_api.helper_never_registered"
    }
  }

  public var domain: String { "PrivateAPI" }

  public var isUserFacing: Bool { true }

  public var title: String { "The Private API helper could not be injected" }

  public var body: String {
    switch self {
    case .dylibMissing(let path): "The helper library is missing at \(path)."
    case .parentApplicationMissing(let name): "\(name) is not installed on this Mac."
    case .architectureMismatch(let dylib, let parent):
      "The helper is built for \(dylib.joined(separator: ", ")) "
        + "but the app is \(parent.joined(separator: ", "))."
    case .helperNeverRegistered(let attempts):
      "The helper was injected but never connected back, after \(attempts) attempts."
    }
  }
}
