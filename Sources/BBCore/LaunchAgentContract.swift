//  LaunchAgentContract
//  What the app, its launch agent and the packaging have to agree on.
//
//  The app is started at login, and brought back when it stops without meaning to, by a launch
//  agent shipped inside its own bundle (`Packaging/com.BlueBubbles.BlueBubbles-Server.agent.plist`,
//  registered through `SMAppService.agent(plistName:)`). launchd does the supervising: the plist
//  says to restart on an unsuccessful exit and to leave a successful one down. So a quit is
//  exit 0, a deliberate restart is `restartExitCode`, and a crash needs nobody's cooperation.
//
//  **Why an agent rather than a helper app that watches this one.** A watcher is a second
//  process that can itself fail, that has to be told a quit from a crash, and whose own
//  registration macOS can lose. launchd already restarts on an unsuccessful exit and leaves a
//  successful one down. Measured on Sonoma 14.6.1, Sequoia 15.6.1 and macOS 27: an agent
//  registered from inside the bundle is named after the app in Login Items and in the
//  Automation prompt, restarted after a `SIGKILL` and after a non-zero exit, and left down
//  after `exit(0)`. `.claude/docs/decisions.md` has the measurement.
//
//  **launchd supervises only what it started.** A copy a person opened, or the copy an updater
//  relaunched, is not the agent's process, so `LaunchAtLogin.handOver` gives it to launchd at
//  startup: it leaves `personHandoverURL` behind so the agent's copy knows a person is
//  watching, asks launchd to start the agent, and exits before it has taken the single-instance
//  lock. `isAgentProcess` is how either copy knows which one it is.

import Foundation

public enum LaunchAgentContract {

  /// The application the agent starts.
  public static let mainBundleIdentifier = "com.BlueBubbles.BlueBubbles-Server"

  /// The agent's launchd label. Must match `Label` in the committed plist, which
  /// `LaunchAgentContractTests` checks.
  public static let label = "com.BlueBubbles.BlueBubbles-Server.agent"

  /// The plist's file name, which is what `SMAppService.agent(plistName:)` takes.
  public static let plistName = "\(label).plist"

  /// Where the plist sits inside the application bundle; the only place SMAppService looks.
  public static let plistBundlePath = "Contents/Library/LaunchAgents/\(plistName)"

  /// The argument the agent starts the app with, so the app can tell nobody opened it by hand.
  ///
  /// **There is no other way to ask.** A GUI app started at login and one double-clicked in
  /// Finder differ in nothing that answers "is somebody watching": `NSApplicationLaunchIsDefaultLaunchKey`
  /// answers a different question (whether a document was opened). The startup delay and
  /// starting minimised are both answers to "nobody is looking", and applied to a person who
  /// has just opened the app they read as a hang, so a launch WITHOUT this is a person.
  public static let automaticLaunchArgument = "--auto-launched"

  /// What a deliberate restart exits with, so launchd brings the app back.
  ///
  /// `EX_TEMPFAIL`: any non-zero status restarts, and this one says "try again" to anybody
  /// reading launchd's record (`last exit code = 75`) rather than reading as a fault.
  public static let restartExitCode: Int32 = 75

  /// The login item the retired helper app registered, so an upgraded install can remove it.
  public static let retiredLauncherIdentifier = "com.BlueBubbles.BlueBubbles-Server.Launcher"

  /// The launch agent the Electron server wrote into `~/Library/LaunchAgents`, which starts the
  /// app at login beside this one on an install upgraded from 1.9.
  public static let electronAgentLabel = "com.bluebubbles.server"

  /// Whether launchd started this process as the agent.
  ///
  /// launchd names its job in `XPC_SERVICE_NAME`. Measured on macOS 27: the agent's process
  /// carries the label exactly, and a copy opened through LaunchServices carries
  /// `application.<bundle identifier>.<numbers>`. The parent is launchd (pid 1) in BOTH cases,
  /// so the parent says nothing.
  public static func isAgentProcess(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    environment["XPC_SERVICE_NAME"] == label
  }

  // MARK: - A person's copy handing over

  /// How long a handover marker is believed. Long enough for launchd to start the agent on a
  /// slow Mac, short enough that one left by a handover that never completed cannot make a
  /// real login look like a person.
  public static let handoverValidity: TimeInterval = 120

  public static var personHandoverURL: URL { personHandoverURL(in: ApplicationSupport.directory) }

  /// The marker inside a given directory. A parameter so a test can use its own; the
  /// `BB_SUPPORT_DIRECTORY` override is process-global and swift-testing runs suites in
  /// parallel.
  public static func personHandoverURL(in directory: URL) -> URL {
    directory.appendingPathComponent("opened-by-person")
  }

  /// Records that a person opened the app, just before it hands over to the agent.
  ///
  /// Best-effort: a marker that fails to write costs a window that starts minimised, not a
  /// server that fails to start.
  public static func markPersonHandover(
    in directory: URL = ApplicationSupport.directory, now: Date = Date()
  ) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stamp = String(now.timeIntervalSince1970)
    try? stamp.write(to: personHandoverURL(in: directory), atomically: true, encoding: .utf8)
  }

  /// Whether this start is one a person's copy handed over, consuming the marker either way.
  ///
  /// Removed on every read, so it applies to one start only: a marker left in place would make
  /// the next login, and every crash restart after it, look like a person.
  public static func consumePersonHandover(
    in directory: URL = ApplicationSupport.directory, now: Date = Date()
  ) -> Bool {
    let url = personHandoverURL(in: directory)
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
    try? FileManager.default.removeItem(at: url)
    guard let written = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    let age = now.timeIntervalSince1970 - written
    return age >= 0 && age <= handoverValidity
  }
}
