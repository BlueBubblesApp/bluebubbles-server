//  PermissionsMonitorService
//  Starts first, because everything else's permission gate reads from it.
//
//  It also watches for a permission being TAKEN AWAY while the server runs, which is a
//  different event from starting without one and used to reach nobody at all. macOS revokes
//  TCC grants on its own: a point update resets them, and re-signing, moving or replacing the
//  app invalidates them. When Full Disk Access goes, the poll starts failing and
//  `ChangeDetector` logs "Poll failed" at `warning` twice a minute for ever — but there was no
//  alert, no `server/info` signal, and headless there is not even a badge, because the only
//  consumers of `unsatisfiedRequired` are SwiftUI views. Messages simply stop arriving and the
//  user has no way to find out why. It is the most likely real failure this server meets.
//
//  And it is where a GRANT reaches the services, which is the same watch in the other
//  direction. macOS sends no notification for either, so whoever follows the probes is the only
//  thing that can know. It hands each one to the registry, which decides from the manifests who
//  it concerns: a service refused at its gate starts, a running one that asked is told. This
//  service knows nothing about either. See `ServiceRegistry.permissionsGranted(_:)`.

import BBBuiltIns
import BBCore
import BBDiagnostics
import BBInterfaces
import BBServiceKit
import BBSystem
import Foundation
import Logging

/// Starts first, because everything else's permission gate reads from it.
actor PermissionsMonitorService: Service {
  static let manifest = BuiltInManifests.permissions
  /// Never worth restarting: a failure here is a failure to read system state, and
  /// retrying immediately would just fail the same way.
  static let restartPolicy = RestartPolicy.never

  typealias Host = any PermissionsProviding & AlertProviding & LoggerProviding
    & HealthChangeReporting & PermissionGrantRouting

  private let permissions: PermissionsService
  private let alerts: AlertCenter
  private let logger: Logger
  /// `health` reads whether every required permission is granted, and a grant moves in
  /// System Settings without the registry doing anything, so each broadcast is reported.
  private let healthReporter: any HealthChangeReporting
  private let grants: any PermissionGrantRouting

  /// What the last broadcast said, so a TRANSITION can be told from a standing state.
  ///
  /// The distinction is the whole point. A server that starts without Full Disk Access is
  /// onboarding's problem and is already reported by every screen; one that had it a minute
  /// ago and does not now is an outage that nothing else notices.
  private var lastStatuses: [PermissionID: PermissionStatus] = [:]
  private let watchTask = OwnedTask()

  init(host: Host) {
    self.permissions = host.permissions
    self.alerts = host.alerts
    self.logger = host.logger
    self.healthReporter = host
    self.grants = host
  }

  func start() async throws {
    lastStatuses = await permissions.checkAll()
    startWatching()
    await permissions.startMonitoring()
  }

  func stop() async {
    await watchTask.stop()
    await permissions.stopMonitoring()
  }

  /// Follows the service's own broadcast rather than polling it again.
  ///
  /// Each automation probe spawns a thread to ask TCC, so a second loop asking the same
  /// question would double the expensive one — which is exactly what `stream()` exists to
  /// prevent. The monitor probes; this listens.
  private func startWatching() {
    let permissions = permissions
    // Replaced, not added to: `start()` can follow a `stop()` on the same instance, and two
    // watchers on one stream would raise every alert twice. `OwnedTask` cancels the previous.
    watchTask.run { [weak self] in
      for await statuses in await permissions.stream() {
        guard let self else { return }
        await self.reactTo(statuses)
      }
    }
  }

  /// Which required permissions went from granted to refused between two broadcasts.
  ///
  /// Static and pure so it can be asserted without TCC: `PermissionsService` asks the real
  /// system, so a test that drove it would report on whatever this Mac happens to be granted.
  /// The decision is the part worth pinning, and it has three edges that are each a way to
  /// get this wrong.
  ///
  /// - A permission with no PREVIOUS reading is not a revocation. The first broadcast after
  ///   start would otherwise report every ungranted permission as freshly taken away.
  /// - `.unknown` is not a refusal. It means the probe could not run, not that anything
  ///   changed, which is why `isDefiniteRefusal` exists rather than `!= .granted`. Alerting
  ///   on a failed probe puts a false outage in front of someone.
  /// - Only `.required` counts. `.recommended` and `.feature` degrade a feature and are
  ///   reported where that feature is; a critical alert for them is noise that teaches people
  ///   to dismiss the one that matters.
  static func revoked(
    from before: [PermissionID: PermissionStatus],
    to now: [PermissionID: PermissionStatus],
    in catalogue: [Permission]
  ) -> [Permission] {
    catalogue.filter { permission in
      guard permission.requirement.isRequired else { return false }
      guard let current = now[permission.id], let previous = before[permission.id] else {
        return false
      }
      return previous == .granted && current.isDefiniteRefusal
    }
  }

  /// Which permissions became granted between two broadcasts.
  ///
  /// Static and pure for the reason `revoked` is. A permission with no PREVIOUS reading is not
  /// a grant: the check at every start already covers what was granted before it, and a
  /// service started then read the permission for itself. Every requirement counts, because
  /// the registry is what decides who a grant concerns.
  static func granted(
    from before: [PermissionID: PermissionStatus],
    to now: [PermissionID: PermissionStatus]
  ) -> Set<PermissionID> {
    Set(
      now.filter { id, status in
        status == .granted && before[id].map { $0 != .granted } == true
      }.keys)
  }

  /// Which permissions somebody has just answered, either way, having never been asked.
  ///
  /// `.unknown` is no answer: it means the probe could not run, and it says nothing about what
  /// the person chose.
  static func answered(
    from before: [PermissionID: PermissionStatus],
    to now: [PermissionID: PermissionStatus]
  ) -> Set<PermissionID> {
    Set(
      now.filter { id, status in
        before[id] == .notDetermined && status != .notDetermined && status != .unknown
      }.keys)
  }

  private func reactTo(_ statuses: [PermissionID: PermissionStatus]) async {
    defer { lastStatuses = statuses }
    // Before the alerts, so the row a person looks at after one already agrees with it.
    if statuses != lastStatuses {
      await healthReporter.serviceHealthDidChange(Self.id)
    }

    // A refusal answers "has anybody asked" as well as a grant does.
    for id in Self.answered(from: lastStatuses, to: statuses) {
      await alerts.dismiss(dedupeKeyPrefix: PermissionNotice.Key.unanswered(id))
    }
    let granted = Self.granted(from: lastStatuses, to: statuses)
    for id in granted {
      // Each would go on saying this is missing beside a service that has just recovered.
      for key in PermissionNotice.Key.missing(id) {
        await alerts.dismiss(dedupeKeyPrefix: key)
      }
      logger.info("A permission was granted", metadata: ["permission": .string(id.rawValue)])
    }
    if !granted.isEmpty {
      await grants.permissionsGranted(granted)
      // Once more, because the probes were read before that opened anything. What a screen
      // derives from a grant (whether `chat.db` is open) is only true of this broadcast.
      await permissions.checkAll()
    }

    for permission in Self.revoked(
      from: lastStatuses, to: statuses, in: permissions.permissions)
    {
      logger.error(
        "A required permission was revoked while the server was running",
        metadata: [
          "permission": .string(permission.id.rawValue),
          "status": .string((statuses[permission.id] ?? .unknown).rawValue),
        ])
      await raise(permission)
    }
  }

  private func raise(_ permission: Permission) async {
    // `why` is written as a capitalised fragment ("Read your Messages database"), so it is
    // lowered into the middle of this sentence rather than dropped in as-is.
    let purpose = permission.why.prefix(1).lowercased() + permission.why.dropFirst()
    var body =
      "\(permission.title) was granted and is not any more, so the server can no longer "
      + "\(purpose). macOS revokes these on its own after a system update, and moving, "
      + "replacing or re-signing the app has the same effect."
    if permission.requiresRelaunch {
      body +=
        " If it still shows as missing after you grant it again, quit and reopen BlueBubbles."
    }
    await alerts.raise(
      UserAlert(
        severity: .critical,
        title: "\(permission.title) was turned off",
        body: body,
        source: "Permissions",
        // The deep link to the exact pane, which already exists on every permission that has
        // one: "open System Settings and find it" is the advice this avoids.
        actions: permission.settingsPane.map { [.openURL($0)] } ?? [.openSettings(.settings)],
        dedupeKey: PermissionNotice.Key.revokedRequired(permission.id),
        // Re-established by the check that runs at every start, so a stale copy cannot claim
        // a permission is missing after the user has restored it.
        isDurable: false
      )
    )
  }

  var health: ServiceHealth {
    get async {
      await permissions.requiredPermissionsSatisfied()
        ? .running
        : .degraded(reason: "a required permission is missing")
    }
  }

  /// Without the watcher a revoked permission raises nothing.
  var isAlive: Bool { get async { watchTask.isRunning } }
}
