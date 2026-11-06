//  LaunchAtLogin
//  Registering the server's launch agent, and handing a hand-opened copy over to it.
//
//  `SMAppService.agent(plistName:)` over the plist the bundle ships at
//  `LaunchAgentContract.plistBundlePath`. launchd starts the app at login and restarts it when
//  it exits unsuccessfully; `LaunchAgentContract` says why that is the whole design.
//
//  **Every `SMAppService` call runs on a thread of its own** (`offThePool`). Each one is a
//  synchronous XPC round trip to Background Task Management, and on a Mac with little memory
//  and a spinning disk one can take minutes. Made on the cooperative pool, which has a thread
//  per core, two of those calls would leave nothing to run the rest of the server on.
//
//  **`status` is trusted, and the registration is never "repaired".** Background Task
//  Management can lose or garble its own records, and nothing an app can read tells that
//  apart reliably from a working registration, and re-registering on a guess churns the very
//  records it means to fix. Switching the setting off and on is the remedy, and it is the
//  person's to apply. Unregistering and registering are what the setting does, nothing else.
//
//  **launchd is asked about its job with `launchctl print`, never `SMAppService.status`, when
//  the answer is needed at startup.** `handOver` runs before the server does, and a status read
//  that takes minutes there is a server that takes minutes to start. `launchctl` reads
//  launchd's own state in milliseconds and ships with every macOS.

import AppKit
import BBCore
import Foundation
import ServiceManagement

public enum LaunchAtLogin {

  public enum Mode: String, Sendable, CaseIterable {
    case none
    /// The launch agent: started at login, restarted when it stops without meaning to.
    ///
    /// The raw value is the stored setting's, from when this was a login item; it is
    /// storage, not a description.
    ///
    /// `SMAppService.daemon` is not an option: it runs pre-login as root, where the user's
    /// login keychain is neither unlocked nor theirs, so every `SecItemCopyMatching` returns
    /// `errSecInteractionNotAllowed` and the server comes up unable to read its own password.
    case loginItem = "login-item"
  }

  public enum Status: String, Sendable, Equatable {
    case enabled
    case notRegistered
    /// The user turned it off in System Settings > General > Login Items. The app must
    /// not silently re-enable it: that is a fight with the user they did not ask for.
    case requiresApproval
    case notFound
    case unknown
  }

  /// Why this copy of the app cannot hold a registration.
  public enum UnsuitableLocation: Sendable, Equatable {
    /// macOS ran a quarantined copy from a randomised read-only path that is gone at the
    /// next login.
    case translocated
    /// A disk image or another read-only volume, which is gone once it is ejected.
    case readOnlyVolume
  }

  /// Everything `decide` needs, gathered by `observe`. Plain values so the decision is
  /// testable without Background Task Management.
  public struct Observation: Sendable, Equatable {
    public var status: Status
    public var agentIsBundled: Bool
    public var unsuitableLocation: UnsuitableLocation?

    public init(
      status: Status, agentIsBundled: Bool = true, unsuitableLocation: UnsuitableLocation? = nil
    ) {
      self.status = status
      self.agentIsBundled = agentIsBundled
      self.unsuitableLocation = unsuitableLocation
    }
  }

  public enum Action: Sendable, Equatable {
    /// Remove the registration.
    case unregister
    /// Nothing to do: registered while it should be, or absent while it should be.
    case leave
    case register
    /// The user has to approve it in System Settings; registering again does not help.
    case awaitApproval
    /// Registering from here would write a record that stops working when this copy goes.
    case refuse(UnsuitableLocation)
    /// This bundle carries no agent plist, so there is nothing to register.
    case notBundled
  }

  /// What to do about the registration.
  ///
  /// An unsuitable location is checked before the status, so a copy run from a disk image
  /// never registers itself over the copy in Applications. `requiresApproval` is never acted
  /// on, because registering again puts the entry back after the user switched it off. An
  /// `.enabled` registration is left alone: see the header on why it is never repaired.
  public static func decide(mode: Mode, _ observation: Observation) -> Action {
    guard mode != .none else {
      switch observation.status {
      case .enabled, .requiresApproval: return .unregister
      case .notRegistered, .notFound, .unknown: return .leave
      }
    }
    guard observation.agentIsBundled else { return .notBundled }
    if let location = observation.unsuitableLocation { return .refuse(location) }
    switch observation.status {
    case .enabled: return .leave
    case .requiresApproval: return .awaitApproval
    case .notRegistered, .notFound, .unknown: return .register
    }
  }

  /// Whether this bundle ships the agent plist.
  ///
  /// `SMAppService.agent` reports a missing plist as `.notFound`, which is indistinguishable
  /// from "not registered yet" at the call site, so the presence check is done here.
  public static var agentIsBundled: Bool {
    FileManager.default.fileExists(
      atPath: Bundle.main.bundleURL.appendingPathComponent(LaunchAgentContract.plistBundlePath)
        .path)
  }

  /// Whether this copy runs from somewhere a registration cannot outlive.
  public static var unsuitableLocation: UnsuitableLocation? {
    let bundle = Bundle.main.bundleURL
    if bundle.path.contains("/AppTranslocation/") { return .translocated }
    let readOnly = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly
    return readOnly == true ? .readOnlyVolume : nil
  }

  private static var service: SMAppService {
    SMAppService.agent(plistName: LaunchAgentContract.plistName)
  }

  /// Everything `decide` needs, read now.
  ///
  /// - Throws: `CancellationError` only.
  public static func observe(mode: Mode) async throws -> Observation {
    Observation(
      status: try await status(),
      agentIsBundled: agentIsBundled,
      unsuitableLocation: unsuitableLocation)
  }

  /// - Throws: `CancellationError` only.
  public static func status() async throws -> Status {
    try await offThePool { currentStatus() }
  }

  private static func currentStatus() -> Status {
    switch service.status {
    case .enabled: return .enabled
    case .notRegistered: return .notRegistered
    case .requiresApproval: return .requiresApproval
    case .notFound: return .notFound
    @unknown default: return .unknown
    }
  }

  /// Registers the agent, after removing the app's own login item (`SMAppService.mainApp`)
  /// that earlier builds registered.
  ///
  /// It goes first because it is a separate entry as far as Background Task Management is
  /// concerned, and left behind it starts a second copy at login that the single-instance
  /// lock then refuses. It is `try?`: one that is not there is what this wants, and the
  /// register reports what actually stops it. The retired helper app's login item is not
  /// unregistered again here: `removeRetiredLauncher` has done it on this start whenever
  /// launchd still holds its job, and every call here is another round trip of minutes on a
  /// busy Mac.
  ///
  /// launchd starts the agent the moment it is registered, so a copy that is already running
  /// meets a second one; `LaunchAgentContract.isAgentProcess` is how that second one knows to
  /// exit quietly.
  ///
  /// - Throws: what Background Task Management answered, or `CancellationError`.
  @discardableResult
  public static func register() async throws -> Status {
    try await offThePool {
      Result {
        try? SMAppService.mainApp.unregister()
        try service.register()
        return currentStatus()
      }
    }.get()
  }

  /// Removes the agent's registration.
  public static func unregister() async {
    // `try?`: cancelled, the thread still finishes the unregister; only the wait ends. A
    // registration that is already gone is what this wants.
    try? await offThePool { try? service.unregister() }
  }

  // MARK: - launchd's own view

  /// What launchd holds for a job in this login session.
  public enum LaunchdJob: Sendable, Equatable {
    /// launchd has no job by that label.
    case absent
    case loaded(LaunchdJobRecord)
    /// `launchctl` did not answer, or answered with something other than a job.
    case unreadable

    /// Loaded and not running: registered, and nothing of it alive right now.
    public var isLoadedAndIdle: Bool {
      guard case .loaded(let record) = self else { return false }
      return record.state != "running"
    }
  }

  /// The few top-level fields of `launchctl print` that say whether a job ran and how it
  /// ended. Each is nil when the output did not carry it.
  public struct LaunchdJobRecord: Sendable, Equatable {
    public var state: String?
    public var runs: Int?
    public var lastExitCode: String?
    public var lastTerminatingSignal: String?

    public init(
      state: String? = nil, runs: Int? = nil, lastExitCode: String? = nil,
      lastTerminatingSignal: String? = nil
    ) {
      self.state = state
      self.runs = runs
      self.lastExitCode = lastExitCode
      self.lastTerminatingSignal = lastTerminatingSignal
    }

    /// Reads a `launchctl print` transcript.
    ///
    /// The format is for people, not a contract, so this reads only the top-level
    /// `key = value` lines (one tab deep, which keeps a nested block's keys out) and ignores
    /// anything it does not recognise. A field that moves reads as nil, never as a wrong
    /// value.
    public static func parse(_ transcript: String) -> LaunchdJobRecord {
      var record = LaunchdJobRecord()
      for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
        guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
        let parts = line.dropFirst().split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        switch key {
        case "state" where record.state == nil: record.state = value
        case "runs" where record.runs == nil: record.runs = Int(value)
        case "last exit code" where record.lastExitCode == nil: record.lastExitCode = value
        case "last terminating signal" where record.lastTerminatingSignal == nil:
          record.lastTerminatingSignal = value
        default: continue
        }
      }
      return record
    }
  }

  private static func target(_ label: String) -> String { "gui/\(getuid())/\(label)" }

  /// Asks launchd about a job. `/bin/launchctl` ships with every macOS.
  public static func launchdJob(label: String = LaunchAgentContract.label) async -> LaunchdJob {
    guard
      let result = try? await Subprocess.run(
        "/bin/launchctl", ["print", target(label)], output: .merged, timeout: .seconds(10))
    else {
      // Reported as `.unreadable`, which every caller treats as "do nothing": a question
      // launchd did not answer must not decide anything.
      return .unreadable
    }
    return interpretLaunchctl(status: result.status, transcript: result.text)
  }

  /// What a `launchctl print` exit status and transcript mean. Separate so it is testable.
  ///
  /// 113 is launchctl's "Could not find service", measured on macOS 27, Sequoia and Sonoma.
  static func interpretLaunchctl(status: Int32, transcript: String) -> LaunchdJob {
    if status == 113 { return .absent }
    guard status == 0 else { return .unreadable }
    let record = LaunchdJobRecord.parse(transcript)
    return record == LaunchdJobRecord() ? .unreadable : .loaded(record)
  }

  /// Asks launchd to start a loaded job now. Measured: a job left down by a clean exit starts
  /// at once, with no Background Task Management round trip.
  ///
  /// - Returns: whether launchctl accepted it. False covers a launchctl that did not answer.
  public static func kickstart(label: String = LaunchAgentContract.label) async -> Bool {
    let result = try? await Subprocess.run(
      "/bin/launchctl", ["kickstart", target(label)], output: .discarded, timeout: .seconds(10))
    return result?.succeeded == true
  }

  /// Removes a job from launchd for this login session. It does not touch the file or the
  /// Background Task Management record behind it.
  ///
  /// - Returns: whether launchctl removed it. False covers a launchctl that did not answer.
  public static func bootout(label: String) async -> Bool {
    let result = try? await Subprocess.run(
      "/bin/launchctl", ["bootout", target(label)], output: .discarded, timeout: .seconds(10))
    return result?.succeeded == true
  }

  // MARK: - Handing a hand-opened copy to the agent

  /// Whether this copy should give way to the agent rather than run the server itself.
  ///
  /// Only a copy launchd did not start, with nothing on its command line, whose agent is
  /// registered and idle. The command line rules out the rest because the agent starts the
  /// app with its own fixed arguments: handing over a `--headless --set …` launch would drop
  /// what the person asked for. A job that is RUNNING is another live copy, which the
  /// single-instance lock answers. Any question launchd did not answer runs here.
  public static func shouldHandOver(
    isAgentProcess: Bool, hasCommandLineOptions: Bool, agentJob: LaunchdJob
  ) -> Bool {
    !isAgentProcess && !hasCommandLineOptions && agentJob.isLoadedAndIdle
  }

  /// Hands this copy over to the agent: leaves the person marker and asks launchd to start
  /// the agent. The caller exits when this returns true, and runs the server itself when it
  /// returns false.
  ///
  /// The marker is withdrawn when launchd refused, so this copy's own start, or a later
  /// login, does not read it.
  public static func handOver() async -> Bool {
    LaunchAgentContract.markPersonHandover()
    guard await kickstart() else {
      _ = LaunchAgentContract.consumePersonHandover()
      return false
    }
    return true
  }

  // MARK: - What earlier installs left behind

  /// Whether launchd still runs the retired helper app's login item.
  public static func retiredLauncherIsLoaded() async -> Bool {
    if case .loaded = await launchdJob(label: LaunchAgentContract.retiredLauncherIdentifier) {
      return true
    }
    return false
  }

  /// Removes the retired helper app's login item: through Background Task Management first,
  /// then from launchd directly if its job is still loaded. The bundle no longer carries the
  /// helper, so the unregister can be refused; the bootout is what stops it either way.
  public static func removeRetiredLauncher() async {
    try? await offThePool {
      try? SMAppService.loginItem(identifier: LaunchAgentContract.retiredLauncherIdentifier)
        .unregister()
    }
    if await retiredLauncherIsLoaded() {
      _ = await bootout(label: LaunchAgentContract.retiredLauncherIdentifier)
    }
  }

  /// What removing the Electron server's launch agent did.
  public enum ElectronAgentRemoval: Sendable, Equatable {
    case notPresent
    /// There, but naming something other than this app's executable. Left alone.
    case notOurs
    case removed
    /// The file is gone, and the job was left loaded because THIS process is it: booting it
    /// out would end the process doing the removal. It does not load at the next login.
    case removedFileOnly
    case failed
  }

  /// The Electron server's agent plist in a home directory.
  public static func electronAgentURL(home: URL) -> URL {
    home.appendingPathComponent(
      "Library/LaunchAgents/\(LaunchAgentContract.electronAgentLabel).plist")
  }

  /// Whether a plist is the Electron server's agent for a BlueBubbles app's executable.
  ///
  /// Both the label and the program, so a file of the same name that runs something else is
  /// never removed: it is somebody's own agent. The program is matched by shape
  /// (`<anything>.app/Contents/MacOS/BlueBubbles`) rather than by this bundle's path, because
  /// the agent was written by whichever copy was installed at the time.
  public static func isElectronAgent(_ plist: [String: Any]) -> Bool {
    guard plist["Label"] as? String == LaunchAgentContract.electronAgentLabel else { return false }
    let program =
      plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
    guard let program else { return false }
    return program.hasSuffix(".app/Contents/MacOS/BlueBubbles")
  }

  /// Removes the Electron server's launch agent, which an upgraded install keeps starting the
  /// app at login beside the agent this build registers.
  public static func removeElectronAgent(
    home: URL = URL(fileURLWithPath: ApplicationSupport.realHomeDirectory, isDirectory: true),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async -> ElectronAgentRemoval {
    let url = electronAgentURL(home: home)
    guard FileManager.default.fileExists(atPath: url.path) else { return .notPresent }
    guard
      let data = try? Data(contentsOf: url),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return .notOurs }
    guard isElectronAgent(plist) else { return .notOurs }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      return .failed
    }
    if environment["XPC_SERVICE_NAME"] == LaunchAgentContract.electronAgentLabel {
      return .removedFileOnly
    }
    _ = await bootout(label: LaunchAgentContract.electronAgentLabel)
    return .removed
  }

  /// Runs a call that blocks its thread on another process, on a thread of its own.
  ///
  /// Not bounded by a deadline: every caller wants the answer however long Background Task
  /// Management takes to give it. What the thread buys is that the wait holds nobody else's
  /// thread. A cancelled caller stops waiting at once and the thread finishes the call
  /// regardless, because a blocked XPC round trip cannot be interrupted; that is what lets a
  /// service's `stop()` wait for its task without waiting a minute for macOS.
  ///
  /// - Throws: `CancellationError` when the caller is cancelled first.
  private static func offThePool<T: Sendable>(
    _ body: @escaping @Sendable () -> T
  ) async throws -> T {
    let answer = OnceContinuation<T>()
    Thread { answer.resume(returning: body()) }.start()
    return try await withTaskCancellationHandler {
      try await answer.value()
    } onCancel: {
      answer.resume(throwing: CancellationError())
    }
  }
}
