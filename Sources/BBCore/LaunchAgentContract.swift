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
//
//  **A quit that never finished stays down too.** launchd cannot tell a Force Quit from a
//  crash: both are a signal. So a person who pressed Quit, watched the shutdown hang and then
//  force-quit got the app straight back. The agent's process leaves `quitRequestURL` behind
//  when a person asks it to quit and removes it on a clean exit. The copy launchd starts next
//  finds it, exits 0 and is left down. The marker names the boot and the login session it was
//  written in, so a reboot or a new login always starts the server, however the last one
//  ended. A Force Quit with no Quit before it still comes back: nothing runs before a
//  `SIGKILL`, so nothing can say that anybody meant it.

import Darwin
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

  // MARK: - A quit that did not finish

  /// The boot and the login a quit marker belongs to.
  ///
  /// Both, because each one ending must start the server again. A shutdown that hangs at a
  /// restart and is killed leaves a marker behind, and the login after the reboot must not
  /// read it; a logout is the same within one boot, and a new login is a new audit session.
  public struct Session: Equatable, Sendable {
    public let bootTime: Int
    public let auditSession: Int32

    public init(bootTime: Int, auditSession: Int32) {
      self.bootTime = bootTime
      self.auditSession = auditSession
    }

    /// This process's boot and login, or nil when the kernel did not say. With no session a
    /// marker is neither written nor honoured, which is the behaviour without this feature.
    public static func current() -> Session? {
      var boot = timeval()
      var size = MemoryLayout<timeval>.size
      guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
        return nil
      }
      var audit = auditinfo_addr()
      guard getaudit_addr(&audit, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 else {
        return nil
      }
      return Session(bootTime: Int(boot.tv_sec), auditSession: audit.ai_asid)
    }
  }

  /// How long a quit marker is believed. launchd restarts a killed job within its
  /// `ThrottleInterval` of the last start, so this only has to outlast the time a person waits
  /// on a hung quit before forcing it; the session check is what keeps it from a later login.
  public static let quitRequestValidity: TimeInterval = 600

  public static var quitRequestURL: URL { quitRequestURL(in: ApplicationSupport.directory) }

  public static func quitRequestURL(in directory: URL) -> URL {
    directory.appendingPathComponent("quit-requested")
  }

  /// Whether a quit should leave the marker.
  ///
  /// Only in the agent's process, because only launchd restarts anything. And not for a
  /// termination signal: one comes from launchd itself as often as from a person
  /// (`launchctl kickstart -k`, a job's exit timeout), and a restart launchd was asked for
  /// must not be refused by the copy it starts.
  public static func marksQuitRequest(isAgentProcess: Bool, initiatedBySignal: Bool) -> Bool {
    isAgentProcess && !initiatedBySignal
  }

  /// Records that a person asked this process to quit. Best-effort: a marker that fails to
  /// write costs a relaunch after a Force Quit, which is the behaviour without it.
  public static func markQuitRequested(
    in directory: URL = ApplicationSupport.directory, now: Date = Date(),
    session: Session? = Session.current()
  ) {
    guard let session else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let record = "\(now.timeIntervalSince1970) \(session.bootTime) \(session.auditSession)"
    try? record.write(to: quitRequestURL(in: directory), atomically: true, encoding: .utf8)
  }

  /// Removes the marker, on a quit that finished. `try?`: one that is not there is the goal.
  public static func clearQuitRequest(in directory: URL = ApplicationSupport.directory) {
    try? FileManager.default.removeItem(at: quitRequestURL(in: directory))
  }

  /// Whether the previous copy was asked to quit in this boot and login and did not get to
  /// finish, consuming the marker either way so it decides one start only.
  public static func consumeQuitRequest(
    in directory: URL = ApplicationSupport.directory, now: Date = Date(),
    session: Session? = Session.current()
  ) -> Bool {
    let url = quitRequestURL(in: directory)
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
    try? FileManager.default.removeItem(at: url)
    let fields = raw.split(separator: " ").map(String.init)
    guard let session, fields.count == 3,
      let written = TimeInterval(fields[0]), let boot = Int(fields[1]),
      let audit = Int32(fields[2].trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    let age = now.timeIntervalSince1970 - written
    return age >= 0 && age <= quitRequestValidity
      && Session(bootTime: boot, auditSession: audit) == session
  }
}
