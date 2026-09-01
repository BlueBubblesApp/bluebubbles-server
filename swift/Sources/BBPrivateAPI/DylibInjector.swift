//  DylibInjector
//  Restarts Messages.app with the helper dylib loaded.
//
//  Unchanged in shape from the current server, because the mechanism is forced by macOS
//  rather than chosen: kill the parent app, relaunch it with `DYLD_INSERT_LIBRARIES` set, and
//  wait for the helper inside it to announce itself. What changes is that the retry policy
//  becomes explicit instead of four counters spread across a loop.
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
//  Both were learned from the observation probe; see swift/docs/OBSERVATION_LADDER.md.
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
  case systemIntegrityProtectionEnabled
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
    /// Application name as it appears in `/Applications`, e.g. `Messages`.
    public let applicationName: String
    /// Bundle identifier the helper reports in its `ping`, e.g. `com.apple.MobileSMS`.
    public let bundleIdentifier: String
    public let dylibPath: String

    public init(applicationName: String, bundleIdentifier: String, dylibPath: String) {
      self.applicationName = applicationName
      self.bundleIdentifier = bundleIdentifier
      self.dylibPath = dylibPath
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
  public func verify() throws {
    guard FileManager.default.fileExists(atPath: target.dylibPath) else {
      throw DylibInjectionError.dylibMissing(path: target.dylibPath)
    }
    guard let executablePath = target.executablePath else {
      throw DylibInjectionError.parentApplicationMissing(name: target.applicationName)
    }

    let dylibArchitectures = processRunner.architectures(of: target.dylibPath)
    let parentArchitectures = processRunner.architectures(of: executablePath)

    // The parent picks its preferred slice, which on Apple Silicon is arm64e. An arm64
    // dylib cannot load into an arm64e process, and dyld says so only on stderr.
    guard !dylibArchitectures.isEmpty, !parentArchitectures.isEmpty else { return }
    guard !Set(dylibArchitectures).isDisjoint(with: Set(parentArchitectures)) else {
      throw DylibInjectionError.architectureMismatch(
        dylib: dylibArchitectures, parent: parentArchitectures
      )
    }
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
          environment: ["DYLD_INSERT_LIBRARIES": target.dylibPath]
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
        "reason": .string(reason),
        "attempt": .stringConvertible(consecutiveFailures),
        "limit": .stringConvertible(policy.maximumConsecutiveFailures),
      ])
  }

  /// Stops retrying and quits the parent application.
  ///
  /// The stopping flag STAYS set — see `inject`, which clears it when a new injection
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
  /// Mach-O slices in a binary, e.g. `["x86_64", "arm64e"]`. Empty when unreadable.
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
    // the app had exited, and the relaunch produced a SECOND copy. Measured — two
    // Messages processes running at once, both writing chat.db, while the endpoint
    // reported a successful restart. `proc_pidpath` sees every process regardless of how
    // it was started, so it is the authority here.
    guard let executablePath = Self.executablePath(forApplicationNamed: name) else { return }

    for _ in 0..<20 {
      if Self.processIdentifiers(running: executablePath).isEmpty { return }
      try? await Task.sleep(for: .milliseconds(500))
    }

    // Still there. Escalate, and keep escalating rather than assuming a signal landed.
    for pid in Self.processIdentifiers(running: executablePath) { kill(pid, SIGTERM) }
    for _ in 0..<8 {
      if Self.processIdentifiers(running: executablePath).isEmpty { return }
      try? await Task.sleep(for: .milliseconds(250))
    }
    for pid in Self.processIdentifiers(running: executablePath) { kill(pid, SIGKILL) }
  }

  /// Both locations, matching `Target.executablePath` — an app installed before Catalina
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
  /// the tests inject a fake through — making one method async would change both, for a
  /// `lipo` call that answers in milliseconds.
  public func architectures(of path: String) -> [String] {
    guard
      let result = try? Subprocess.runSynchronously(
        "/usr/bin/lipo", ["-archs", path],
        output: .standardOutputOnly, timeout: .seconds(15)
      ),
      result.succeeded
    else { return [] }
    return result.trimmedText.split(separator: " ").map(String.init)
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
    case .systemIntegrityProtectionEnabled: "private_api.system_integrity_protection_enabled"
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
    case .systemIntegrityProtectionEnabled:
      "System Integrity Protection blocks injection. The Private API cannot run until it is disabled."
    case .helperNeverRegistered(let attempts):
      "The helper was injected but never connected back, after \(attempts) attempts."
    }
  }
}
