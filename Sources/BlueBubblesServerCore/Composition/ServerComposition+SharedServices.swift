//  ServerComposition+SharedServices
//  The cross-cutting services everything else is built on, and the policy they read.
//
//  Built in one place because the order between them is load-bearing: the audit recorder
//  exists before anything that records into it, the alert centre is attached to its store
//  before anything can raise, and access control reads back its persisted blocks before
//  anything is served. The access policy and the permission notice live here because
//  this is where they are first applied; `SettingsPropagation` re-reads the policy on a
//  settings change.

import BBAppStore
import BBAudit
import BBAuth
import BBContacts
import BBCore
import BBDiagnostics
import BBHandlers
import BBLicensing
import BBProxy
import BBServiceKit
import BBSettings
import BBSystem
import Foundation

extension ServerComposition {

  // MARK: - Cross-cutting

  /// The four services everything else is built on top of.
  struct SharedServices: Sendable {
    let alerts: AlertCenter
    let permissions: PermissionsService
    let accessControl: AccessControlService
    let contacts: ContactIndex
    /// Built here, before the access controller and the transport, because both record
    /// into it from their construction. Inert until `AuditLogService` arms it.
    let auditLog: AuditRecorder
    /// Built here rather than by `LicenseService`, because it holds the license key and the
    /// key is a secret no service may declare a read of. Also because the HTTP service needs
    /// the same instance and neither service may construct the other's state.
    let license: LicenseRuntime
    /// Where every tunnel daemon this server spawns is recorded, and what the next start
    /// reaps from. One per server and passed down, never a process-wide default: a test or
    /// a redirected run that reached the real installation's file would be recording pids
    /// into the list a real server SIGTERMs. See `DaemonLedger`.
    let daemonLedger: DaemonLedger
  }

  /// Builds the alert centre, the permission monitor, access control and the contact index.
  static func makeSharedServices(storage: Storage) async -> SharedServices {
    let appDatabase = storage.appDatabase
    let settings = storage.settings

    // The audit recorder, built before the first thing that records into it. The observers
    // that feed it from objects built in this function are attached as those are built;
    // the settings store's below. It is disarmed until the audit log service arms it.
    let auditLog = AuditRecorder()

    // The endpoint is composition-time, so it is read once here. The KEY is not read at
    // all: `LicenseStore` holds the store and answers questions about the key without
    // returning it. The runtime reports what it finds and does to the audit log, which is
    // why the recorder is built first.
    let license = LicenseRuntime(
      store: LicenseStore(settings: settings),
      client: EntitlementClient(
        endpoint: await settings.get(Settings.licenseEndpoint),
        serverVersion: ServerVersion.current
      ),
      machine: MachineFingerprint.of(seed: MachineIdentity.stableSeed),
      auditor: AuditLicenseBridge(recorder: auditLog)
    )

    let alerts = AlertCenter()
    // Attached before anything can raise, so an alert from start-up (the likeliest moment
    // for one) is stored rather than being the one that gets lost. Restoring happens here
    // too: what comes back is what was unread and undismissed within the retention window,
    // with live-condition alerts restored already-read so a problem that cleared while the
    // server was down does not greet the user as current.
    await alerts.attach(store: AlertRepository(database: appDatabase))

    // The settings store is told about the recorder here rather than in `prepareStorage`,
    // which has no recorder yet; a write made before this line (the log level, say) is
    // start-up bookkeeping the audit log would drop as disarmed anyway.
    await settings.attachAuditObserver(AuditSettingsBridge(recorder: auditLog))

    // The settings store is built before this point, so a Keychain failure during
    // start-up (the likeliest moment for one, and the one that decides whether the
    // server can authenticate at all) has nowhere to be reported until now. Attaching
    // drains anything already held.
    await settings.attachAlerts(alerts)

    let permissions = PermissionsService(
      onChange: { id, from, to in
        // A permission revoked after setup (which happens on OS upgrades) is
        // reported when it breaks rather than surfacing later as odd failures.
        guard let alert = Self.revocationAlert(for: id, from: from, to: to) else { return }
        await alerts.raise(alert)
      }
    )

    let accessControl = AccessControlService(
      policy: await accessPolicy(from: settings),
      trust: await proxyTrust(from: settings),
      alerts: alerts,
      persistence: AccessControlStore(database: appDatabase),
      auditor: AuditAccessControlBridge(recorder: auditLog)
    )
    // Read back BEFORE anything is served, so a client blocked before the restart does
    // not get one free window, and an administrator's allowlist is in force from the
    // first request rather than from whenever they next open the Security page.
    await accessControl.loadPersistedState()
    await accessControl.trustLocalNetwork(await settings.get(Settings.trustLocalNetwork))

    return SharedServices(
      alerts: alerts,
      permissions: permissions,
      accessControl: accessControl,
      contacts: ContactIndex(database: appDatabase),
      auditLog: auditLog,
      license: license,
      // Resolved here, from the same support directory as `app.db`, so a run redirected by
      // `BB_SUPPORT_DIRECTORY` keeps its daemons in its own tree.
      daemonLedger: DaemonLedger(
        file: ApplicationSupport.directory.appendingPathComponent("daemons.json"))
    )
  }

  // MARK: - Access policy

  /// The whole policy, not just the on/off switch.
  ///
  /// `rate_limit_failures` and `rate_limit_block_seconds` were declared, rendered in the
  /// Security section, and read by nothing, so moving either slider changed no behaviour.
  static func accessPolicy(from settings: SettingsStore) async -> AccessControlPolicy {
    var policy = AccessControlPolicy()
    policy.isEnabled = await settings.get(Settings.rateLimitEnabled)
    policy.perClientThreshold = max(1, await settings.get(Settings.rateLimitFailureThreshold))
    policy.baseLockout = .seconds(max(1, await settings.get(Settings.rateLimitBlockSeconds)))
    // Kept above the base so escalation has somewhere to go, whatever the operator set.
    policy.maximumLockout = max(policy.baseLockout, .seconds(86_400))
    return policy
  }

  /// Who is allowed to set `X-Forwarded-For`, from `trusted_proxies`.
  ///
  /// Loopback is always included and cannot be configured away: the managed ngrok,
  /// cloudflared, zrok and tailscaled processes all connect over it, and dropping it would
  /// make every
  /// tunnelled client unattributable.
  static func proxyTrust(from settings: SettingsStore) async -> ProxyTrustPolicy {
    var trust = ProxyTrustPolicy()
    let declared = await settings.get(Settings.trustedProxies)
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    trust.trustedProxies.formUnion(declared)
    return trust
  }

  // MARK: - Permission notices

  /// The notice for a permission that was granted and is not any more, or nil when there is
  /// none to raise HERE.
  ///
  /// **`.unknown` IS NOT A REVOCATION**, and treating it as one produced 112 "A permission
  /// was revoked" notifications for `automation-messages` on a permission the Permissions
  /// page correctly showed as granted the whole time. The probe returns it whenever
  /// `AEDeterminePermissionToAutomateTarget` overruns `tccProbeDeadline`, so a busy `tccd`
  /// became a warning about a permission nobody had touched. Only a DEFINITE negative is
  /// worth waking somebody for; `.restricted` counts, because MDM or parental controls
  /// really did take it away.
  ///
  /// A REQUIRED permission is `PermissionsMonitorService`'s to report, with a critical
  /// notice naming what stopped and a link to the pane. Raising this one as well gave a
  /// single revocation two notices under two dedupe keys.
  static func revocationAlert(
    for id: PermissionID, from: PermissionStatus, to: PermissionStatus
  ) -> UserAlert? {
    guard from == .granted, to.isDefiniteRefusal else { return nil }
    let permission = PermissionsService.catalogue.first { $0.id == id }
    if permission?.requirement.isRequired == true { return nil }
    return UserAlert(
      severity: .warning,
      title: "A permission was revoked",
      body: "\(permission?.title ?? id.rawValue) is no longer granted, so some features have "
        + "stopped working.",
      source: "Permissions",
      // Coalesced: a permission that flaps must not produce one alert per two-second
      // refresh.
      dedupeKey: "permission.\(id.rawValue)"
    )
  }
}
