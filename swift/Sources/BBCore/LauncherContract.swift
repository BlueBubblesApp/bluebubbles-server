//  LauncherContract
//  The two facts the app and its launcher must agree on: who they are, and why the app stopped.
//
//  The launcher is a small bundle at `Contents/Library/LoginItems/` registered with
//  `SMAppService.loginItem(identifier:)`. It exists for one reason the main app cannot supply
//  for itself: **a process cannot restart itself after it dies.** `ServerLifecycle` could
//  already replace the process image with `execv`, which covers a DELIBERATE restart and
//  nothing else: a crash, an OOM kill, a `SIGKILL` leaves nothing running and nothing
//  watching. Supervision has to come from a second process that outlives the first.
//
//  **Why a file rather than XPC or a distributed notification.** The question the launcher
//  asks is "why did the app stop", and it asks it AFTER the app is gone, so the answer has to
//  outlive the process that gave it. A notification is delivered to whoever is listening at
//  the time and is lost otherwise, which is precisely wrong for a message whose entire purpose
//  is to survive the sender. An XPC connection dies with the app and cannot carry a final
//  word either. A file written before exit is still there afterwards, and a crash (which
//  writes nothing) correctly leaves the previous value in place.
//
//  That is the design rule worth keeping: **`supervise` is what a crash looks like.** It is
//  the resting value, and every other intent is written deliberately and reset after it is
//  read. Anything that fails to write its intent is treated as an unexpected death, which is
//  the safe direction: the cost of a wrong guess is an app that comes back when the user
//  meant to quit, not one that stays down when they needed it up.

import Foundation

public enum LauncherContract {

  /// The application the launcher supervises.
  public static let mainBundleIdentifier = "com.BlueBubbles.BlueBubbles-Server"

  /// The launcher itself. Must match `CFBundleIdentifier` in the bundle `build-app.sh`
  /// assembles, and the identifier passed to `SMAppService.loginItem(identifier:)`: macOS
  /// matches on it exactly, and a mismatch reports `.notFound` rather than an error naming
  /// the problem.
  public static let launcherBundleIdentifier = "com.BlueBubbles.BlueBubbles-Server.Launcher"

  /// Where the launcher bundle sits inside the application bundle. `SMAppService.loginItem`
  /// reads this path and no other.
  public static let launcherBundlePath = "Contents/Library/LoginItems/BlueBubblesLauncher.app"

  /// Why the application stopped.
  public enum Intent: String, Sendable, Equatable {
    /// Keep it running. The resting value, and therefore what a crash looks like.
    case supervise
    /// The user quit. Stay down until the next login.
    case quit
    /// Bring it straight back.
    case restart
  }

  public static var intentURL: URL { intentURL(in: ApplicationSupport.directory) }

  /// The intent file inside a given directory.
  ///
  /// The directory is a parameter so a test can use its own without touching
  /// `BB_SUPPORT_DIRECTORY`. That override is process-global, and swift-testing runs suites in
  /// parallel: a test that sets it redirects every other suite running at that instant, which
  /// showed up as `ApplicationSupportTests` intermittently asserting against a temp path it had
  /// never heard of. Injection is not just tidier here; the env var cannot be made safe.
  public static func intentURL(in directory: URL) -> URL {
    directory.appendingPathComponent("launcher-intent")
  }

  /// Reads the intent, defaulting to `.supervise`.
  ///
  /// A missing or unreadable file reads as `.supervise` on purpose: the file is absent on a
  /// first run and after any failure to write one, and both of those are cases where the app
  /// stopped without saying why, which is what `.supervise` means.
  public static func readIntent(in directory: URL = ApplicationSupport.directory) -> Intent {
    guard let raw = try? String(contentsOf: intentURL(in: directory), encoding: .utf8)
    else { return .supervise }
    return Intent(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .supervise
  }

  /// Records why the application is about to stop.
  ///
  /// Best-effort and deliberately not throwing. Every caller is on a path that is already
  /// committed (the user has quit, or a restart is under way) and there is nothing useful
  /// to do with a failure at that point. Failing to write leaves `.supervise`, which brings
  /// the app back; that is the direction to fail in.
  public static func writeIntent(
    _ intent: Intent, in directory: URL = ApplicationSupport.directory
  ) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? intent.rawValue.write(to: intentURL(in: directory), atomically: true, encoding: .utf8)
  }
}
