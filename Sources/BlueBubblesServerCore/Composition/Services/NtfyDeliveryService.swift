//  NtfyDeliveryService
//  Publishes events to an ntfy topic.
//
//  Carved out of `WebhookDeliveryService`, which registered both sinks. That arrangement had
//  three consequences and none of them was intended: ntfy's configuration lived in the
//  WEBHOOK manifest's entitlements, ntfy stopped whenever webhooks were switched off, and
//  there was no way to see on the Integrations page that ntfy was a thing this server does.
//  Event sinks are additive by category, so two services is what the model already expected.
//
//  An install that had ntfy configured before it was an integration is adopted on the first
//  start; that lives in `NtfySettingsAdoption`, which says why it is code rather than a
//  `FieldMigration`.

import BBBuiltIns
import BBDiagnostics
import BBEvents
import BBInterfaces
import BBServiceKit
import BBSettings
import Logging

actor NtfyDeliveryService: Service, ConfigurableService {
  static let manifest = BuiltInManifests.ntfy
  /// A topic that refuses a publish is the topic's problem, not ours; the provider reports
  /// a persistent failure and there is nothing here to restart.
  static let restartPolicy = RestartPolicy.never

  typealias Host = any SettingsProviding & AlertProviding & EventPublishing
    & NotificationSinkProviding

  private let scoped: ScopedSettings
  /// The raw store, for the two reads the scope cannot serve: this service's own secret
  /// field, and the legacy `ntfy_token`, which is a core secret and which no entitlement may
  /// name -- `ManifestValidator` refuses a manifest that tries.
  private let settings: SettingsStore
  private let events: EventBus
  private let notifications: NotificationSink
  private let logger = Logger(label: "bluebubbles.ntfy")

  init(host: Host) {
    self.scoped = ScopedSettings(
      store: host.settings, manifest: Self.manifest, secretKeys: Settings.secretKeys
    )
    self.settings = host.settings
    self.events = host.events
    self.notifications = host.notifications
  }

  /// The manifest's own fields, plus the secret one.
  ///
  /// `manifestWatchedSettings` is built from declared entitlements and this service declares
  /// no `readSettings`: its configuration is its own namespace, which the scope grants
  /// without one. So the watch list is assembled here, and the token is in it because a
  /// changed access token has to re-attach the provider like any other field.
  static var watchedSettings: Set<String> {
    Set(manifest.fields.map { manifest.storageKey(for: $0.key) })
  }

  func start() async throws {
    // Once, and only for an install that had ntfy configured before it was an integration.
    // Off the actor so it can be tested without a whole `Host`; see `NtfySettingsAdoption`
    // for why it is code rather than a `FieldMigration`.
    if try await NtfySettingsAdoption.run(store: settings, manifest: Self.manifest) {
      // Named at `info` because it moved somebody's configuration: a support log for a
      // server whose ntfy suddenly looks different needs to say this ran. Neither the topic
      // nor the token is in the line — the topic is a shared secret by design, and the token
      // is a credential.
      logger.info("Adopted the previous ntfy settings into this integration")
    }

    let topic = await scoped.own(NtfySettingsAdoption.Field.topic).trimmingCharacters(
      in: .whitespaces)
    // Not configured is not a failure. An ntfy-less install is the common one, and a sink
    // that declines every event is indistinguishable from a configured one that is failing.
    guard !topic.isEmpty else { return }

    // An unreadable Keychain gives nil, which here is treated as no token: ntfy accepts
    // unauthenticated publishes to a public topic, so the sink stays up rather than taking
    // the server down with it. The alert the store raises is what reports it.
    // Through the raw store by KEY: `secret(_:)` takes a declared `Setting`, and this is a
    // manifest field. The store routes a secret key to the Keychain either way, and an
    // unreadable one answers nil, which is read here as no token rather than as a failure.
    let token =
      await settings.string(forKey: Self.manifest.storageKey(for: NtfySettingsAdoption.Field.token))
      ?? ""

    let eventNames = await scoped.own(NtfySettingsAdoption.Field.events)
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    // Cleared to nothing means nothing, not everything. The field ships as `*`, so an empty
    // value is somebody deliberately unticking every box, and a sink registered to accept no
    // event is the inert-but-present state this project keeps finding. So it is not
    // registered at all, and the log says which of the two states this is.
    guard !eventNames.isEmpty else {
      logger.info("ntfy topic is set but no events are selected; ntfy is not attached")
      return
    }
    logger.info("ntfy attached", metadata: ["events": .stringConvertible(eventNames.count)])

    await events.register(notifications)
    await notifications.attach(
      NtfyProvider(
        target: NtfyTarget(
          serverURL: await scoped.own(NtfySettingsAdoption.Field.server),
          topic: topic,
          accessToken: token.isEmpty ? nil : token,
          events: eventNames
        )
      )
    )
  }

  func stop() async {
    await notifications.detach(providerID: NtfyProvider.identifier)
    // Symmetric with `PushDeliveryService.stop`: the shared sink leaves the bus only when
    // the last provider has gone, or detaching ntfy would silently stop push too.
    if await notifications.attachedProviderIDs.isEmpty {
      await events.unregister(.push)
    }
  }

  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      let topic = await scoped.own(NtfySettingsAdoption.Field.topic).trimmingCharacters(
        in: .whitespaces)
      guard !topic.isEmpty else { return .inactive(reason: "no ntfy topic configured") }
      // A topic subscribed to no events delivers nothing, so it does not count as
      // configured: reporting "running" for it would describe a provider never attached.
      let events = await scoped.own(NtfySettingsAdoption.Field.events).trimmingCharacters(
        in: .whitespaces)
      guard !events.isEmpty else {
        return .inactive(reason: "ntfy topic is set but no events are selected")
      }
      return .running
    }
  }

}
