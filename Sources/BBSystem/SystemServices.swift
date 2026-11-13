//  SystemServices
//  System facilities called natively rather than through a subprocess.
//
//  A shell-out costs a fork+exec, parses text that was never meant to be an API, and fails
//  in ways that read as "the command produced unexpected output" rather than as the thing
//  that actually went wrong.
//
//  See `.claude/docs/performance.md`.

import AppKit
import BBCore
import Foundation
import IOKit.pwr_mgt
import Logging

// MARK: - Sleep prevention

/// Keeps the Mac awake while the server is running.
///
/// Not `caffeinate -i -m -s -w <pid>`: a subprocess whose lifetime is tied to ours by pid can
/// outlive an uncleanly killed server and hold the machine awake indefinitely with nothing
/// left to explain why.
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

  /// Prevents idle sleep. The display is deliberately allowed to sleep: the server needs
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

// MARK: - Application control

/// Starting, stopping and hiding other applications.
///
/// `NSRunningApplication` rather than `osascript` or `killall "<name>"`. `killall` matches on a
/// process name string, which will happily terminate an unrelated process that happens to
/// share it; `NSRunningApplication` addresses a specific application.
public enum ApplicationControl {

  public static func isRunning(bundleIdentifier: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
  }

  /// Asks politely, then insists.
  ///
  /// `terminate()` sends a Quit Apple Event, which lets the application save state: the
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

    do {
      let exited = try await poll(.every(.milliseconds(200)), within: timeout) { _ in
        isRunning(bundleIdentifier: bundleIdentifier) ? nil : true
      }
      if exited != nil { return true }
    } catch {
      // Cancelled: the polite request stands, and nothing is forced on behalf of a caller
      // that has gone. A loop that slept with `try?` here spun until the deadline instead,
      // then force-quit Messages for nobody.
      return !isRunning(bundleIdentifier: bundleIdentifier)
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

  /// Opens System Settings at a specific pane.
  @discardableResult
  public static func open(_ url: URL) -> Bool {
    NSWorkspace.shared.open(url)
  }
}

/// Locking the screen.
///
/// There is no public API for this. The two available routes are a private Login framework
/// symbol and the `pmset displaysleepnow` command; the latter is what the reference
/// uses and what this keeps, because a private symbol that vanishes in a point release turns
/// into a crash rather than a clean failure.
public enum ScreenLock {

  public enum ScreenLockError: BBError, Equatable {
    case failed(status: Int32)
  }

  /// Locks the screen.
  ///
  /// `SACLockScreenImmediate` in the private `login.framework`, which is what the menu-bar
  /// "Lock Screen" item calls.
  /// Resolved through `dlopen`/`dlsym` rather than linked, so a macOS that moves or removes
  /// it degrades to the fallback instead of failing to launch the whole server.
  ///
  /// The distinction from the fallback is not cosmetic. `pmset displaysleepnow` sleeps the
  /// DISPLAY, which locks only if the user has "require password after sleep" enabled, so
  /// on a Mac without that setting the fallback dims the screen and leaves it unlocked.
  /// This locks regardless.
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
  /// Resolved lazily and then immutable: a `dlsym` result pointing at code, which is
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

  /// The fallback.
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
