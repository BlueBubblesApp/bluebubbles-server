//  SystemServices
//  Native replacements for the shell-outs.
//
//  The current server makes about twenty distinct subprocess invocations. Each one costs a
//  fork+exec, parses text that was never meant to be an API, and fails in ways that read as
//  "the command produced unexpected output" rather than as the thing that actually went
//  wrong. These are the replacements that carry real weight.
//
//  See `.claude/docs/performance.md`.

import AppKit
import BBCore
import Foundation
import IOKit.pwr_mgt
import Logging
import ServiceManagement

// MARK: - Sleep prevention

/// Keeps the Mac awake while the server is running.
///
/// Replaces `caffeinate -i -m -s -w <pid>`, a subprocess whose lifetime is tied to ours by
/// pid — so if the server is killed uncleanly, the caffeinate process can outlive it and hold
/// the machine awake indefinitely with nothing left to explain why.
///
/// An IOPMAssertion has no such failure mode: it is owned by this process and released by the
/// kernel when the process dies, however it dies.
public actor SleepPrevention {

  private let logger: Logger
  private var assertionID: IOPMAssertionID?

  public init(logger: Logger = Logger(label: "bluebubbles.system.sleep")) {
    self.logger = logger
  }

  public var isActive: Bool { assertionID != nil }

  /// Prevents idle sleep. The display is deliberately allowed to sleep — the server needs
  /// the machine awake, not the screen on, and holding the display awake is a battery and
  /// burn-in cost for nothing.
  public func begin(reason: String = "BlueBubbles Server is running") {
    guard assertionID == nil else { return }

    var identifier = IOPMAssertionID(0)
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertPreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason as CFString,
      &identifier
    )
    guard result == kIOReturnSuccess else {
      logger.warning(
        "Could not prevent sleep",
        metadata: [
          "code": .stringConvertible(result)
        ])
      return
    }
    assertionID = identifier
    logger.info("Preventing idle sleep")
  }

  public func end() {
    guard let assertionID else { return }
    IOPMAssertionRelease(assertionID)
    self.assertionID = nil
    logger.info("Released the sleep assertion")
  }

  deinit {
    // Belt and braces. The kernel releases assertions when a process exits, so this
    // matters only for a long-lived process that drops the object.
    if let assertionID { IOPMAssertionRelease(assertionID) }
  }
}

// MARK: - Launch at login

/// Registers the server to start automatically.
///
/// Replaces `launchctl` plus a hand-written LaunchAgent plist. The plist approach means
/// writing a file into `~/Library/LaunchAgents` with the correct label, program arguments and
/// escaping, then invoking `launchctl load` — and a malformed plist fails at login, silently,
/// long after the mistake was made.
public enum LaunchAtLogin {

  public enum Mode: String, Sendable, CaseIterable {
    case none
    /// The app itself, launched at login.
    case loginItem = "login-item"
    /// A per-user LaunchAgent.
    ///
    /// NOT a way to run without a login session, which an earlier version of this
    /// comment claimed. `SMAppService.agent` loads into the user's Aqua session at
    /// login and unloads at logout, exactly like `.loginItem` — it differs only in
    /// being launchd-supervised, so it restarts if it crashes. Nothing here runs
    /// before a user logs in.
    ///
    /// That distinction is load-bearing for secrets: `SMAppService.daemon` WOULD run
    /// pre-login as root, where the user's login keychain is not unlocked and not
    /// theirs, so every `SecItemCopyMatching` returns `errSecInteractionNotAllowed`
    /// and the server comes up unable to read its own password. Adding `.daemon` here
    /// therefore requires moving secrets out of the login keychain first.
    case launchAgent = "launch-agent"
  }

  public enum Status: String, Sendable, Equatable {
    case enabled
    case notRegistered
    /// The user turned it off in System Settings > General > Login Items. The app must
    /// not silently re-enable it — that is a fight with the user they did not ask for.
    case requiresApproval
    case notFound
    case unknown
  }

  public static func status(mode: Mode, agentPlistName: String? = nil) -> Status {
    let service: SMAppService
    switch mode {
    case .none: return .notRegistered
    case .loginItem: service = SMAppService.mainApp
    case .launchAgent:
      guard let agentPlistName else { return .notFound }
      service = SMAppService.agent(plistName: agentPlistName)
    }

    switch service.status {
    case .enabled: return .enabled
    case .notRegistered: return .notRegistered
    case .requiresApproval: return .requiresApproval
    case .notFound: return .notFound
    @unknown default: return .unknown
    }
  }

  @discardableResult
  public static func register(mode: Mode, agentPlistName: String? = nil) throws -> Status {
    switch mode {
    case .none:
      try? SMAppService.mainApp.unregister()
      return .notRegistered
    case .loginItem:
      try SMAppService.mainApp.register()
      return status(mode: mode)
    case .launchAgent:
      guard let agentPlistName else { return .notFound }
      try SMAppService.agent(plistName: agentPlistName).register()
      return status(mode: mode, agentPlistName: agentPlistName)
    }
  }

  public static func unregister(mode: Mode, agentPlistName: String? = nil) throws {
    switch mode {
    case .none: break
    case .loginItem: try SMAppService.mainApp.unregister()
    case .launchAgent:
      guard let agentPlistName else { return }
      try SMAppService.agent(plistName: agentPlistName).unregister()
    }
  }
}

// MARK: - Application control

/// Starting, stopping and hiding other applications.
///
/// Replaces `osascript` for app lifecycle and `killall "<name>"`. `killall` matches on a
/// process name string, which will happily terminate an unrelated process that happens to
/// share it; `NSRunningApplication` addresses a specific application.
public enum ApplicationControl {

  public static func isRunning(bundleIdentifier: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
  }

  /// Asks politely, then insists.
  ///
  /// `terminate()` sends a Quit Apple Event, which lets the application save state — the
  /// difference between quitting Messages and killing it mid-write.
  public static func quit(
    bundleIdentifier: String,
    timeout: Duration = .seconds(10)
  ) async -> Bool {
    let running = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    )
    guard !running.isEmpty else { return true }
    for application in running { application.terminate() }

    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if !isRunning(bundleIdentifier: bundleIdentifier) { return true }
      try? await Task.sleep(for: .milliseconds(200))
    }

    for application in NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ) {
      application.forceTerminate()
    }
    return !isRunning(bundleIdentifier: bundleIdentifier)
  }

  /// Launches an application by bundle identifier.
  ///
  /// Synchronous by design: the caller wants to know whether the launch was ACCEPTED, not
  /// whether the app has finished starting. Messages takes seconds to come up and waiting
  /// for that would block a request for no benefit.
  @discardableResult
  public static func launch(bundleIdentifier: String) -> Bool {
    guard
      let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleIdentifier
      )
    else { return false }

    let configuration = NSWorkspace.OpenConfiguration()
    // Not activated: restarting Messages should not steal focus from whatever the user
    // is doing, and this is usually triggered remotely.
    configuration.activates = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    return true
  }

  public static func hide(bundleIdentifier: String) {
    for application in NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ) {
      application.hide()
    }
  }

  /// Opens System Settings at a specific pane.
  @discardableResult
  public static func open(_ url: URL) -> Bool {
    NSWorkspace.shared.open(url)
  }

  /// Reveals a path in Finder.
  ///
  /// Used by the Full Disk Access step: the user has to drag the app into a list, and
  /// making them find it themselves is where that step usually goes wrong.
  public static func revealInFinder(path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
}

// MARK: - Locale

/// Replaces `defaults read -g AppleLanguages | sed …`.
///
/// The region drives phone-number formatting, so getting it wrong means every bare national
/// number resolves to the wrong country code.
public enum SystemLocale {
  public static var regionCode: String {
    Locale.current.region?.identifier ?? "US"
  }
}

/// Locking the screen.
///
/// There is no public API for this. The two available routes are a private Login framework
/// symbol and the `pmset displaysleepnow` command; the latter is what the current server
/// uses and what this keeps, because a private symbol that vanishes in a point release turns
/// into a crash rather than a clean failure.
public enum ScreenLock {

  public enum ScreenLockError: BBError, Equatable {
    case failed(status: Int32)
  }

  /// Locks the screen.
  ///
  /// `SACLockScreenImmediate` in the private `login.framework`, which is what the current
  /// server's bundled Python script calls and what the menu-bar "Lock Screen" item calls.
  /// Resolved through `dlopen`/`dlsym` rather than linked, so a macOS that moves or removes
  /// it degrades to the fallback instead of failing to launch the whole server.
  ///
  /// The distinction from the fallback is not cosmetic. `pmset displaysleepnow` sleeps the
  /// DISPLAY, which locks only if the user has "require password after sleep" enabled — so
  /// on a Mac without that setting, "lock my Mac" from a phone dimmed the screen and left
  /// it unlocked while reporting success. This locks regardless.
  public static func lock() async throws {
    if let immediate = lockScreenImmediate {
      let status = immediate()
      guard status != 0 else { return }
      // Fall through to the fallback rather than reporting failure: a non-zero return
      // here is rare and undocumented, and dimming the screen beats doing nothing.
    }
    try await sleepDisplay()
  }

  /// `SACLockScreenImmediate`, resolved once.
  ///
  /// Resolved lazily and then immutable — a `dlsym` result pointing at code, which is
  /// Sendable on its own and needs no concurrency annotation.
  private static let lockScreenImmediate: (@convention(c) () -> Int32)? = {
    guard
      let handle = dlopen(
        "/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY
      )
    else { return nil }
    guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
      dlclose(handle)
      return nil
    }
    // The handle is deliberately not closed: the function pointer stays live for the
    // process, and unloading the image under it would leave a dangling call.
    return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
  }()

  /// The fallback, and what this used to do unconditionally.
  private static func sleepDisplay() async throws {
    let result = try await Subprocess.run(
      "/usr/bin/pmset", ["displaysleepnow"], output: .discarded, timeout: .seconds(10)
    )
    guard result.succeeded else {
      throw ScreenLockError.failed(status: result.status)
    }
  }
}

extension ScreenLock.ScreenLockError {
  public var code: String { "system.screen_lock_failed" }
  public var domain: String { "System" }
  public var title: String { "Could not lock the Mac" }

  public var body: String {
    if case .failed(let status) = self {
      return "The lock request returned status \(status)."
    }
    return "The lock request failed."
  }

  public var context: [String: DiagnosticValue] {
    if case .failed(let status) = self { return ["status": .int(Int(status))] }
    return [:]
  }
}
