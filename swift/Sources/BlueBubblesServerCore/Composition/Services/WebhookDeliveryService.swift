//  WebhookDeliveryService
//  Registers the webhook and ntfy sinks so subscribed endpoints actually receive events.

import BBBuiltIns
import BBDiagnostics
import BBEvents
import BBInterfaces
import BBServiceKit
import BBSettings

/// Registers the webhook sink so subscribed endpoints actually receive events.
///
/// Its own service rather than part of push, because the two are independent delivery routes
/// and a webhook-only install is a first-class deployment: several users run ntfy and no
/// Firebase at all.
actor WebhookDeliveryService: Service, ConfigurableService {
  static let manifest = BuiltInManifests.webhooks
  /// A failing endpoint is the endpoint's problem, not ours; the sink alerts once a
  /// failure becomes persistent and there is nothing here to restart.
  static let restartPolicy = RestartPolicy.never

  /// What this service touches, rather than the container that holds it.
  ///
  /// Six capabilities is wide, and it is honest: this service registers a sink on the bus,
  /// negotiates a codec for it, reports failures, reads its own configuration and owns
  /// notification delivery. Every one of them is used.
  typealias Host = any SettingsProviding & AlertProviding & CodecProviding & EventPublishing
    & NotificationSinkProviding & WebhookAdministering

  /// The three ntfy fields the manifest declares.
  private let scoped: ScopedSettings
  /// The raw store, for ONE read the scope cannot serve: `ntfy_token` is a secret, and no
  /// entitlement may name a secret; `ManifestValidator` refuses a manifest that tries.
  private let settings: SettingsStore
  private let alerts: AlertCenter
  private let codecs: CodecNegotiator
  private let events: EventBus
  private let notifications: NotificationSink
  /// The container rebuilds this per read from the same tracker and repository, so holding
  /// one is holding all of them.
  private let webhooks: WebhookDirectory

  init(host: Host) {
    self.scoped = ScopedSettings(
      store: host.settings, manifest: Self.manifest, secretKeys: Settings.secretKeys
    )
    self.settings = host.settings
    self.alerts = host.alerts
    self.codecs = host.codecs
    self.events = host.events
    self.notifications = host.notifications
    self.webhooks = host.webhooks
  }

  /// The manifest's ntfy reads, plus the token: a secret, which no entitlement may name and
  /// which therefore cannot reach the default.
  static var watchedSettings: Set<String> {
    manifestWatchedSettings.union([Settings.ntfyToken.key])
  }

  func start() async throws {
    // Targets are read per event rather than captured: a webhook added through the API
    // has to start receiving without a restart, which a snapshot taken here would not.
    // `WebhookDirectory` is a Sendable struct over the repository, so this closure holds
    // nothing that points back at the container.
    let directory = webhooks
    await events.register(
      WebhookSink(
        targets: { await directory.targets() },
        negotiator: codecs,
        alerts: alerts,
        // Shared with the context so delivery history outlives a restart of this
        // service, and so the settings page has something to read.
        deliveries: directory.deliveries
      )
    )

    // ntfy is registered only when a topic is configured. An unconfigured sink that
    // declines every event is indistinguishable from a configured one that is failing,
    // and it is the second state an operator needs to be able to see.
    let topic = try await scoped.get(Settings.ntfyTopic)
      .trimmingCharacters(in: .whitespaces)
    guard !topic.isEmpty else { return }

    // An unreadable Keychain gives nil, which here is treated as no token: ntfy accepts
    // unauthenticated publishes to a public topic, so the sink stays up rather than
    // taking the server down with it. The alert raised by the store is what reports it.
    let token = await settings.secret(Settings.ntfyToken)?.unsafeStringValue() ?? ""

    // The event filter for the ntfy target. An empty or absent setting means everything,
    // which is what existing installs already get.
    let ntfyEventNames = try await scoped.get(Settings.ntfyEvents)
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    // Cleared to nothing means nothing, not everything. The setting ships as `*`, so an
    // empty value is someone deliberately unticking every box, and a sink registered to
    // accept no event is the inert-but-present state this project keeps finding, so it is
    // not registered at all. The settings row says so where the boxes are unticked.
    guard !ntfyEventNames.isEmpty else { return }

    await events.register(notifications)
    await notifications.attach(
      NtfyProvider(
        target: NtfyTarget(
          serverURL: try await scoped.get(Settings.ntfyServer),
          topic: topic,
          accessToken: token.isEmpty ? nil : token,
          events: ntfyEventNames
        )
      )
    )
  }

  func stop() async {
    await events.unregister(.webhook)
    // Detached rather than unregistering the sink: Firebase may still be attached to it,
    // and pulling the sink off the bus would silently stop push as well.
    await notifications.detach(providerID: "ntfy")
  }

  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      let configured = await webhooks.targets().count
      // A topic subscribed to no events delivers nothing, so it does not count as
      // configured; reporting "running" for it would describe a sink that was never
      // registered.
      let topic = await scoped.valueOrDefault(Settings.ntfyTopic)
      let ntfyEvents = await scoped.valueOrDefault(Settings.ntfyEvents)
      let ntfy =
        !topic.isEmpty
        && !ntfyEvents.trimmingCharacters(in: .whitespaces).isEmpty
      guard configured > 0 || ntfy else {
        return .inactive(reason: "no webhooks or ntfy topic configured")
      }
      return .running
    }
  }
}
