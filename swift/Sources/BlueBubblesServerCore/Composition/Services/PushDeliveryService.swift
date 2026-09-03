//  PushDeliveryService
//  Firebase Cloud Messaging as a registry service. Optional: declines when unconfigured.

import BBBuiltIns
import BBDiagnostics
import BBEvents
import BBPushKit
import BBServiceKit
import BBSettings

actor PushDeliveryService: ContextualService, GatedService, ConfigurableService {
  static let manifest = BuiltInManifests.push

  let context: AppContext
  private let credentials: PushCredentialStore
  /// Reachable so `PushInterface` can drive setup — importing credentials, provisioning a
  /// project, sending a test notification — against the SAME service the sink delivers
  /// through, rather than a second one that would have its own token cache and its own idea
  /// of whether push is configured.
  let push: PushService

  init(host: AppContext) {
    let app = host
    self.context = app
    // The SHARED Keychain store, not a fresh in-memory one. With its own store this
    // would find no credentials, decline to run, and report "push is not configured" on
    // a machine where it demonstrably is.
    let credentials = PushCredentialStore(secrets: app.secrets)
    self.credentials = credentials
    self.push = PushService(
      credentials: credentials,
      // Push's own notices — credentials moved to the Keychain, a project Google says is
      // gone, insecure rules repaired. Each is a distinct event, so no dedupe key.
      alerts: AlertCenterReporter(center: app.alerts, source: "Push", severity: .warning),
      onRestart: { await app.requestRestart() },
      pruneTokens: { tokens in await app.deviceDirectory.prune(tokens: tokens) },
      persistLastRestart: { timestamp in
        await app.settings.trySet(Settings.lastFcmRestart, to: Int(timestamp))
      },
      serverURL: { await app.settings.get(Settings.serverAddress) }
    )
  }

  /// Push is optional. With no credentials this declines, the server starts clean, and
  /// nothing is logged as a defect — the opposite of today's `postChecks` nagging.
  ///
  /// It reads the CREDENTIAL STORE, not the service. `push.isConfigured` reports what the
  /// last `start` found, and the gate runs BEFORE `start` — so asking the service was
  /// asking a question whose answer is always "no" on a server that has not started push
  /// yet, which is every server. Push was gated off on every install, including fully
  /// configured ones: nothing failed, no warning was logged, and no notification was ever
  /// sent. Measured by the wiring test that now pins this.
  func canRun() async -> Bool { await credentials.isConfigurable() }

  /// The manifest's read — `server_address` — plus the remote-restart switch, which has no
  /// presentation (its control is on the Firebase page) and so cannot be declared without
  /// putting a column name on the permissions list.
  static var watchedSettings: Set<String> {
    manifestWatchedSettings.union([Settings.remoteRestartEnabled.key])
  }

  func start() async throws {
    // Read here rather than at construction: the registry builds services synchronously
    // and settings are actor-isolated, so there is no `await` available in `init`.
    await push.configure(
      PushConfiguration(
        remoteRestartEnabled: await context.settings.get(Settings.remoteRestartEnabled),
        lastHonouredRestart: Int64(await context.settings.get(Settings.lastFcmRestart))
      )
    )
    await push.start()
    // Handed to the context rather than looked up from it: see `AppContext.pushDelivery`.
    await context.publish(pushDelivery: push)

    // Registering the sink is what makes push actually deliver. Without it the service
    // starts, reports itself configured, and is never asked to send anything: the bus
    // fans out only to sinks that registered, and this one never did. Nothing failed —
    // `server/info` said push was active and Android clients received nothing.
    // The sink is shared with every other notification transport and registering it is
    // idempotent — whichever service starts first puts it on the bus, and the second
    // replaces it with the same object. Attaching is what makes THIS transport deliver.
    await context.events.register(context.notifications)
    await context.notifications.attach(
      FirebaseProvider(
        service: push,
        tokens: { [weak context] in await context?.deviceDirectory.tokens() ?? [] },
        negotiator: context.codecs
      )
    )
  }

  /// Turning remote restart off has to stop the poll, which means rebuilding the watcher —
  /// there is nothing to reconfigure in place. The other declared read, `server_address`, is
  /// consumed live: the URL publisher reads it on every publish and the announcer pushes a
  /// changed one through `PushService.publish`, so a restart would only cost a token mint.
  func apply(_ change: SettingsChange) async throws -> ReloadAction {
    change.contains(Settings.remoteRestartEnabled.key) ? .restart : .none
  }

  func stop() async {
    await context.withdrawPushDelivery()
    await context.events.unregister(.push)
    await push.stop()
  }

  var health: ServiceHealth { get async { .running } }
}
