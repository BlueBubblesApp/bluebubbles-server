//  Permissions
//  macOS permissions as declared descriptors, checked authoritatively.
//
//  The problem being fixed
//  ----------------------
//  Today a permission that was not granted up front becomes a mysterious failure much later.
//  Three things cause that, and each is addressed here:
//
//    1. **The probes are unreliable.** `hasFullDiskAccess()` shells out to
//       `defaults read com.apple.universalaccessAuthWarning.plist` and string-matches the
//       output. That file has nothing to do with Full Disk Access. The authoritative check is
//       to open `chat.db` — if it opens, we have the access; if it does not, we do not.
//    2. **Checks are one-shot.** Flipping a toggle in System Settings does not update the app,
//       so a user who grants a permission still sees it as missing and concludes it did not
//       work. Status here is re-checked continuously.
//    3. **Nothing gates on them.** A service whose permission is missing starts anyway and
//       fails obscurely at first use. `ServiceRegistry` refuses to start it and says why.
//
//  **Accessibility is deliberately absent.** It existed solely for the UI-automation scripts
//  dropped in § 14 — one fewer alarming permission in onboarding, and a direct dividend of
//  that decision.
//
//  See `docs/AUTH.md`.

import AppKit
import BBCore
import BBServiceKit
import Contacts
import Foundation
import Logging
import UserNotifications

public enum PermissionStatus: String, Sendable, Equatable, Codable {
  case granted
  case denied
  /// Never asked. Distinct from `denied`, because one is worth prompting for and the other
  /// needs the user to go to System Settings — advice that is wrong for the other case.
  case notDetermined
  /// Blocked by policy — MDM, parental controls. No prompt will help.
  case restricted
  /// The check could not run. Reported rather than guessed at.
  case unknown
}

/// How much a permission matters.
public enum PermissionRequirement: Sendable, Equatable {
  case required
  case recommended
  /// Required only for a named feature, which is what the user is told.
  case feature(String)

  public var isRequired: Bool {
    if case .required = self { return true }
    return false
  }
}

public struct Permission: Sendable, Identifiable {
  public let id: PermissionID
  public let title: String
  /// One user-facing sentence, always shown. A permission request without a reason is a
  /// permission users deny.
  public let why: String
  public let requirement: PermissionRequirement
  /// Deep link to the exact pane, not "open System Settings and find it".
  public let settingsPane: URL?
  /// Full Disk Access needs the app added by hand and then relaunched. Both are stated.
  public let requiresRelaunch: Bool
  /// Whether the app can prompt, or the user must go to System Settings themselves.
  public let canPrompt: Bool

  public init(
    id: PermissionID,
    title: String,
    why: String,
    requirement: PermissionRequirement,
    settingsPane: URL? = nil,
    requiresRelaunch: Bool = false,
    canPrompt: Bool = false
  ) {
    self.id = id
    self.title = title
    self.why = why
    self.requirement = requirement
    self.settingsPane = settingsPane
    self.requiresRelaunch = requiresRelaunch
    self.canPrompt = canPrompt
  }
}

public struct PermissionState: Sendable, Equatable {
  public let id: PermissionID
  public let status: PermissionStatus
  public let checkedAt: Date

  public init(id: PermissionID, status: PermissionStatus, checkedAt: Date = Date()) {
    self.id = id
    self.status = status
    self.checkedAt = checkedAt
  }
}

// MARK: - Deep links

public enum SettingsPane {

  /// Pane identifiers changed in Ventura, which is below our macOS 14 floor — so one set of
  /// URLs covers every supported release and no version branching is needed.
  static func url(_ anchor: String) -> URL? {
    URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
  }

  public static let fullDiskAccess = url("Privacy_AllFiles")
  public static let automation = url("Privacy_Automation")
  public static let contacts = url("Privacy_Contacts")
  public static let notifications = URL(
    string: "x-apple.systempreferences:com.apple.preference.notifications")
}

// MARK: - Probes

/// The actual checks, behind a protocol so the service can be tested without the real system
/// state — which on a CI machine is neither granted nor deniable.
public protocol PermissionProbing: Sendable {
  func fullDiskAccess() async -> PermissionStatus
  func automation(bundleIdentifier: String) async -> PermissionStatus
  func contacts() async -> PermissionStatus
  func notifications() async -> PermissionStatus
  func systemIntegrityProtectionDisabled() async -> PermissionStatus

  /// Prompts, where prompting is possible. Returns nil when there is nothing to ask —
  /// Full Disk Access and SIP have no dialog, so the caller re-reads the real status
  /// rather than being handed an invented one.
  func requestAccess(to id: PermissionID, bundleIdentifier: String) async -> PermissionStatus?
}

extension PermissionProbing {
  /// Default for probes that only observe, which is every test double.
  public func requestAccess(to id: PermissionID, bundleIdentifier: String) async
    -> PermissionStatus?
  {
    nil
  }
}

public struct SystemPermissionProbe: PermissionProbing {

  private let chatDatabasePath: String

  public init(
    chatDatabasePath: String = NSHomeDirectory() + "/Library/Messages/chat.db"
  ) {
    self.chatDatabasePath = chatDatabasePath
  }

  /// Authoritative: open the file we actually need.
  ///
  /// `FileManager.isReadableFile` is not enough — it consults the filesystem permission
  /// bits, which say yes even when TCC will refuse the open. Only opening it settles the
  /// question, and it is exactly the operation the server performs anyway.
  public func fullDiskAccess() async -> PermissionStatus {
    guard FileManager.default.fileExists(atPath: chatDatabasePath) else {
      // No Messages database at all. Not a permission problem, and reporting it as one
      // would send the user to the wrong settings pane.
      return .unknown
    }
    do {
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: chatDatabasePath))
      defer { try? handle.close() }
      // Read a byte: opening can succeed lazily on some paths.
      _ = try handle.read(upToCount: 1)
      return .granted
    } catch {
      return .denied
    }
  }

  /// A real tri-state, versus today's try-and-fail.
  ///
  /// `askUserIfNeeded: false` matters — passing true would show a consent dialog as a side
  /// effect of *checking*, which is how a status page ends up prompting the user every time
  /// they look at it.
  /// **OFF THE COOPERATIVE POOL, AND BOUNDED.** Both halves are load-bearing, and neither
  /// was here.
  ///
  /// `AEDeterminePermissionToAutomateTarget` is a synchronous C call that makes an XPC
  /// round trip to `tccd`. Calling it directly from an `async` function blocks a thread the
  /// Swift concurrency runtime owns and expects back — and the runtime has only as many of
  /// those as the machine has cores. When `tccd` did not answer, startup reached this point
  /// and stopped: the HTTP listener was bound (NIO runs its own threads) while every async
  /// task behind it starved, so the port accepted connections that were never served. From
  /// the outside that looks like a hung server with no error anywhere.
  ///
  /// `tccd` fails to answer for reasons that have nothing to do with this app. It stalls
  /// most readily for a process it cannot attribute to a bundle — an unbundled `swift run`
  /// binary is attributed to the terminal that spawned it — which is precisely the
  /// development configuration.
  ///
  /// So: run it on a thread that is ours to block, and give up after `deadline`. An
  /// unanswered probe is `.unknown`, which is what the type is for.
  public func automation(bundleIdentifier: String) async -> PermissionStatus {
    await Self.boundedSyncProbe(deadline: Self.tccProbeDeadline) {
      var target = AEAddressDesc()
      let created = bundleIdentifier.withCString { pointer -> OSErr in
        AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
      }
      guard created == noErr else { return .unknown }
      defer { AEDisposeDesc(&target) }

      switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) {
      case noErr: return .granted
      case OSStatus(errAEEventNotPermitted): return .denied
      case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
      case OSStatus(procNotFound): return .unknown  // the target is not installed
      default: return .unknown
      }
    }
  }

  /// Long enough that a busy but working `tccd` still answers, short enough that a wedged
  /// one does not hold up a server start.
  static let tccProbeDeadline = Duration.seconds(5)

  /// Runs a blocking probe on a dedicated thread, answering `.unknown` if it overruns.
  ///
  /// The thread is deliberately abandoned rather than cancelled on timeout: a blocked
  /// `mach_msg` cannot be interrupted, and pretending otherwise would swap one hang for a
  /// crash. It is one thread, it ends when `tccd` finally replies, and nothing waits on it.
  static func boundedSyncProbe(
    deadline: Duration,
    _ probe: @escaping @Sendable () -> PermissionStatus
  ) async -> PermissionStatus {
    await withTaskGroup(of: PermissionStatus?.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          let thread = Thread { continuation.resume(returning: probe()) }
          thread.stackSize = 512 * 1024
          thread.start()
        }
      }
      group.addTask {
        try? await Task.sleep(for: deadline)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first ?? .unknown
    }
  }

  /// Prompts for a permission the app is allowed to ask for.
  ///
  /// Kept separate from the probes on purpose. A check that prompts as a side effect turns
  /// a status page into a nag — the user opens Permissions, gets three dialogs, and learns
  /// to dismiss them without reading. Asking happens only when someone presses a button
  /// that says so.
  ///
  /// Returns the status AFTER the prompt resolves, so a caller can act on the answer
  /// rather than polling for it.
  public func requestAccess(to id: PermissionID, bundleIdentifier: String) async
    -> PermissionStatus?
  {
    switch id {
    case .contacts:
      // The completion handler fires on an arbitrary queue; the continuation is what
      // makes it awaitable without blocking one.
      _ = await withCheckedContinuation { continuation in
        CNContactStore().requestAccess(for: .contacts) { granted, _ in
          continuation.resume(returning: granted)
        }
      }
      return await contacts()

    case .notifications:
      guard Bundle.main.bundleIdentifier != nil else { return .unknown }
      _ = try? await UNUserNotificationCenter.current()
        .requestAuthorization(options: [.alert, .sound])
      return await notifications()

    case .automationMessages:
      // The ONLY place `askUserIfNeeded: true` is passed. There is no separate request
      // API for Apple Events — the consent dialog is a side effect of the check — so
      // requesting means deliberately doing the thing the probes avoid.
      var target = AEAddressDesc()
      let created = bundleIdentifier.withCString { pointer -> OSErr in
        AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
      }
      guard created == noErr else { return .unknown }
      defer { AEDisposeDesc(&target) }
      _ = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
      return await automation(bundleIdentifier: bundleIdentifier)

    default:
      // Nothing else can be prompted for. Full Disk Access requires the user to add
      // the app by hand in System Settings — macOS shows no dialog at all — and SIP is
      // a Recovery-mode setting. Returning `nil` says "there was nothing to ask" so
      // the caller re-reads the real status rather than trusting a made-up answer.
      return nil
    }
  }

  public func contacts() async -> PermissionStatus {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized: .granted
    case .denied: .denied
    case .restricted: .restricted
    case .notDetermined: .notDetermined
    @unknown default: .unknown
    }
  }

  public func notifications() async -> PermissionStatus {
    // `UNUserNotificationCenter.current()` does not fail gracefully outside an app
    // bundle — it raises `NSInternalInconsistencyException`, which is not catchable from
    // Swift and takes the process down. The server runs unbundled in development and
    // under a launch agent, so this is a normal configuration, not an edge case.
    //
    // A bundle identifier is the thing it actually requires, so that is what is checked.
    guard Bundle.main.bundleIdentifier != nil else { return .unknown }

    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral: return .granted
    case .denied: return .denied
    case .notDetermined: return .notDetermined
    @unknown default: return .unknown
    }
  }

  /// SIP status, for the Private API explainer.
  ///
  /// `csr_check` is resolved dynamically because it is not in any public header — declaring
  /// it would be relying on a private symbol at link time, which breaks the build if it is
  /// ever removed. Resolved at runtime, its absence degrades to the `csrutil` fallback.
  ///
  /// Read-only: this is never something the app offers to change. Disabling SIP is a
  /// Recovery-mode operation and the app has no business attempting it.
  public func systemIntegrityProtectionDisabled() async -> PermissionStatus {
    typealias CSRCheck = @convention(c) (UInt32) -> Int32
    // CSR_ALLOW_UNRESTRICTED_FS. Returns 0 when the protection is PERMITTED — that is,
    // when SIP is not enforcing it.
    let unrestrictedFilesystem: UInt32 = 1 << 1

    if let symbol = dlsym(dlopen(nil, RTLD_NOW), "csr_check") {
      let check = unsafeBitCast(symbol, to: CSRCheck.self)
      return check(unrestrictedFilesystem) == 0 ? .granted : .denied
    }
    return await csrutilFallback()
  }

  /// Shelling out only when the symbol is gone.
  private func csrutilFallback() async -> PermissionStatus {
    // Was `readDataToEndOfFile()` + `waitUntilExit()` inline in an `async` function, which
    // parked a cooperative-pool thread for the length of the call.
    guard
      let result = try? await Subprocess.run(
        "/usr/bin/csrutil", ["status"],
        output: .standardOutputOnly, timeout: .seconds(10)
      )
    else { return .unknown }

    let output = result.text.lowercased()
    if output.contains("disabled") { return .granted }
    if output.contains("enabled") { return .denied }
    return .unknown
  }
}

// MARK: - The service

public actor PermissionsService {

  /// How often live status re-checks. Frequent enough that flipping a System Settings
  /// toggle updates the app while the user is still looking at it — the single biggest
  /// usability gap today — and cheap enough to leave running.
  public static let liveRefreshInterval: Duration = .seconds(2)

  private let probe: any PermissionProbing
  private let logger: Logger
  private let onChange: @Sendable (PermissionID, PermissionStatus, PermissionStatus) async -> Void

  private var states: [PermissionID: PermissionState] = [:]
  private var monitorTask: Task<Void, Never>?

  public init(
    probe: any PermissionProbing = SystemPermissionProbe(),
    logger: Logger = Logger(label: "bluebubbles.permissions"),
    onChange: @escaping @Sendable (PermissionID, PermissionStatus, PermissionStatus) async -> Void =
      { _, _, _ in }
  ) {
    self.probe = probe
    self.logger = logger
    self.onChange = onChange
  }

  /// The declared list. Order is the order onboarding presents them.
  public nonisolated var permissions: [Permission] {
    [
      Permission(
        id: .fullDiskAccess,
        title: "Full Disk Access",
        why: "Read your Messages database",
        requirement: .required,
        settingsPane: SettingsPane.fullDiskAccess,
        // The step users most often get half-right: the app must be added by hand
        // and then relaunched before the grant takes effect.
        requiresRelaunch: true
      ),
      Permission(
        id: .automationMessages,
        title: "Automation → Messages",
        why: "Send messages without the Private API",
        // Required only when the Private API is unavailable; with it, sending does
        // not go through AppleScript at all.
        requirement: .feature("Sending without the Private API"),
        settingsPane: SettingsPane.automation,
        canPrompt: true
      ),
      Permission(
        id: .contacts,
        title: "Contacts",
        why: "Show names instead of phone numbers",
        requirement: .recommended,
        settingsPane: SettingsPane.contacts,
        canPrompt: true
      ),
      Permission(
        id: .notifications,
        title: "Notifications",
        why: "Alert you when something needs attention",
        requirement: .recommended,
        settingsPane: SettingsPane.notifications,
        canPrompt: true
      ),
      Permission(
        id: .systemIntegrityProtection,
        title: "System Integrity Protection disabled",
        why: "Enables reactions, edit and unsend, typing indicators, and group management",
        requirement: .feature("Private API"),
        // Deliberately no settings pane: this is a Recovery-mode operation and there
        // is nothing to deep-link to.
        settingsPane: nil
      ),
    ]
  }

  // MARK: Checking

  /// Messages.app — the only automation target the server drives.
  static let messagesBundleIdentifier = "com.apple.MobileSMS"

  /// Prompts for a permission, then re-checks it.
  ///
  /// The re-check is the point: the prompt's own return value tells you what the user
  /// tapped, while the status is what the system actually recorded, and for Automation
  /// those can differ. Storing the re-checked value keeps the page honest.
  @discardableResult
  public func request(_ id: PermissionID) async -> PermissionStatus {
    _ = await probe.requestAccess(
      to: id,
      bundleIdentifier: Self.messagesBundleIdentifier
    )
    return await check(id)
  }

  public func check(_ id: PermissionID) async -> PermissionStatus {
    let status: PermissionStatus
    switch id {
    case .fullDiskAccess: status = await probe.fullDiskAccess()
    case .automationMessages:
      status = await probe.automation(bundleIdentifier: "com.apple.MobileSMS")
    case .contacts: status = await probe.contacts()
    case .notifications: status = await probe.notifications()
    case .systemIntegrityProtection: status = await probe.systemIntegrityProtectionDisabled()
    default: status = .unknown
    }

    let previous = states[id]?.status
    states[id] = PermissionState(id: id, status: status)

    if let previous, previous != status {
      // A permission revoked after setup — which happens on OS upgrades — is reported
      // at the moment it breaks rather than surfacing later as unexplained failures.
      logger.info(
        "Permission changed",
        metadata: [
          "permission": .string(id.rawValue),
          "from": .string(previous.rawValue),
          "to": .string(status.rawValue),
        ])
      await onChange(id, previous, status)
    }
    return status
  }

  @discardableResult
  public func checkAll() async -> [PermissionID: PermissionStatus] {
    var result: [PermissionID: PermissionStatus] = [:]
    for permission in permissions {
      result[permission.id] = await check(permission.id)
    }
    return result
  }

  public func status(of id: PermissionID) -> PermissionStatus {
    states[id]?.status ?? .unknown
  }

  public func allStates() -> [PermissionState] {
    permissions.compactMap { states[$0.id] }
  }

  /// Whether every REQUIRED permission is granted. What onboarding gates on.
  public func requiredPermissionsSatisfied() -> Bool {
    permissions
      .filter { $0.requirement.isRequired }
      .allSatisfy { states[$0.id]?.status == .granted }
  }

  public func unsatisfiedRequired() -> [Permission] {
    permissions.filter { $0.requirement.isRequired && states[$0.id]?.status != .granted }
  }

  // MARK: Live status

  /// Starts continuous re-checking.
  ///
  /// This is what makes the page feel correct: granting a permission in System Settings and
  /// switching back shows it granted, with no relaunch and no navigating away and back.
  public func startMonitoring() {
    guard monitorTask == nil else { return }
    monitorTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.checkAll()
        try? await Task.sleep(for: Self.liveRefreshInterval)
      }
    }
  }

  public func stopMonitoring() {
    monitorTask?.cancel()
    monitorTask = nil
  }

  // MARK: Preflight

  /// Whether a service may start.
  ///
  /// Wired into `ServiceRegistry`'s permission gate, so a service whose permission is
  /// missing reports `.inactive` with a precise reason instead of failing obscurely the
  /// first time it touches something.
  public func permissionCheck() -> @Sendable (PermissionID) async -> Bool {
    { [weak self] id in
      guard let self else { return false }
      return await self.check(id) == .granted
    }
  }
}

extension PermissionID {
  /// Read-only, and not a permission the app can request — it is a Recovery-mode setting.
  /// Modelled here anyway so the Private API's requirement is expressed the same way as
  /// every other prerequisite rather than as a special case.
  public static let systemIntegrityProtection = PermissionID("sip-disabled")
}
