//  PushDeliveryService
//  Firebase Cloud Messaging as a registry service. Optional: declines when unconfigured.

import BBBuiltIns
import BBDiagnostics
import BBEvents
import BBInterfaces
import BBPushKit
import BBServiceKit
import BBSettings

actor PushDeliveryService: Service, GatedService, ConfigurableService {
  static let manifest = BuiltInManifests.push

  /// What this service touches, rather than the container that holds it.
  ///
  /// Nine capabilities, and the width is the point rather than an accident of the rewrite:
  /// this one type constructs the whole push stack, gates on the credential store,
  /// registers a sink, and publishes a runtime. Every capability below is used, and the
  /// list is the evidence that those are four jobs rather than one. Splitting it is a
  /// separate change; naming what it reaches is what makes the case for it.
  typealias Host = any ScopedSettingsProviding & SecretStoreProviding & AlertProviding
    & CodecProviding & EventPublishing & NotificationSinkProviding
    & DeviceDirectoryProviding & ServerControlling & PushDeliveryPublishing
    & ServerMetricsProviding

  private let host: Host
  /// Every setting this service touches, checked against what its manifest declares.
  private let scoped: ScopedSettings
  private let events: EventBus
  private let notifications: NotificationSink
  private let codecs: CodecNegotiator
  /// A `Sendable` struct over the device table, so the sink's token closure holds nothing
  /// that points back at the container.
  private let deviceDirectory: DeviceDirectory
  private let credentials: PushCredentialStore
  /// Reachable so `PushInterface` can drive setup (importing credentials, provisioning a
  /// project, sending a test notification) against the SAME service the sink delivers
  /// through, rather than a second one that would have its own token cache and its own idea
  /// of whether push is configured.
  let push: PushService

  init(host: Host) {
    let app = host
    let scopedForURL = app.scopedSettings(for: Self.manifest)
    self.host = app
    self.scoped = scopedForURL
    self.events = app.events
    self.notifications = app.notifications
    self.codecs = app.codecs
    self.deviceDirectory = app.deviceDirectory
    // The SHARED Keychain store, not a fresh in-memory one. With its own store this
    // would find no credentials, decline to run, and report "push is not configured" on
    // a machine where it demonstrably is.
    let credentials = PushCredentialStore(secrets: app.secrets)
    self.credentials = credentials
    self.push = PushService(
      credentials: credentials,
      // Push's own notices: credentials moved to the Keychain, a project Google says is
      // gone, insecure rules repaired. Each is a distinct event, so no dedupe key.
      alerts: AlertCenterReporter(center: app.alerts, source: "Push", severity: .warning),
      // Scheduled, never awaited: the watcher calls this from its own poll task, and the
      // restart stops this service, which stops the watcher. Awaited there, the restart
      // cancelled the task that was running it, part-way through bringing the server back.
      onRestart: { await app.scheduleRestart(.services, after: .zero) },
      pruneTokens: { tokens in await app.deviceDirectory.prune(tokens: tokens) },
      persistLastRestart: { timestamp in
        await scopedForURL.trySet(Settings.lastFcmRestart, to: Int(timestamp))
      },
      serverURL: { await scopedForURL.valueOrDefault(Settings.serverAddress) },
      onReport: { [metrics = app.metrics] report in metrics.notePush(report) }
    )
  }

  /// Push is optional. With no credentials this declines, the server starts clean, and
  /// nothing is logged as a defect.
  ///
  /// It reads the CREDENTIAL STORE, not the service. `push.isConfigured` reports what the
  /// last `start` found, and the gate runs BEFORE `start`, so asking the service would be
  /// asking a question whose answer is always "no" on a server that has not started push
  /// yet, which is every server. `PushWiringTests` pins this.
  func canRun() async -> Bool { await credentials.isConfigurable() }

  /// The manifest's read (`server_address`) plus the remote-restart switch, which has no
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
        remoteRestartEnabled: try await scoped.get(Settings.remoteRestartEnabled),
        lastHonouredRestart: Int64(try await scoped.get(Settings.lastFcmRestart))
      )
    )
    await push.start()
    // Handed to the context rather than looked up from it: see `AppContext.pushDelivery`.
    await host.publish(pushDelivery: push)

    // Joining the shared notification lane is what makes push actually deliver. Without it
    // the service starts, reports itself configured, and is never asked to send anything:
    // the bus fans out only to sinks that registered, and nothing fails visibly. See
    // `NotificationSink+Lane`.
    let directory = deviceDirectory
    await notifications.join(
      FirebaseProvider(
        service: push,
        tokens: { await directory.tokens() },
        negotiator: codecs
      ),
      on: events
    )
  }

  /// Turning remote restart off has to stop the poll, which means rebuilding the watcher:
  /// there is nothing to reconfigure in place. The other declared read, `server_address`, is
  /// consumed live: the URL publisher reads it on every publish and the announcer pushes a
  /// changed one through `PushService.publish`, so a restart would only cost a token mint.
  func apply(_ change: SettingsChange) async throws -> ReloadAction {
    change.contains(Settings.remoteRestartEnabled.key) ? .restart : .none
  }

  func stop() async {
    await host.withdrawPushDelivery()
    // Leaves the shared lane rather than unregistering it: ntfy may still be on it.
    await notifications.leave(providerID: FirebaseProvider.identifier, from: events)
    await push.stop()
  }

  var health: ServiceHealth { get async { .running } }
}
