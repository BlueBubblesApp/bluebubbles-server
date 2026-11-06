//  NtfyDeliveryService
//  Publishes events to an ntfy topic.
//
//  Carved out of `WebhookDeliveryService`, which registered both sinks. That arrangement had
//  three consequences and none of them was intended: ntfy's configuration lived in the
//  WEBHOOK manifest's entitlements, ntfy stopped whenever webhooks were switched off, and
//  there was no way to see on the Integrations page that ntfy was a thing this server does.
//  Event sinks are additive by category, so two services is what the model already expected.
//
//  An install that had ntfy configured before it was an integration is adopted before any
//  service starts, by the composition root; that lives in `NtfySettingsAdoption`, which says
//  why it is not this service's job.

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

  typealias Host = any ScopedSettingsProviding & EventPublishing & NotificationSinkProviding

  /// Every read, the access token included: a service's own fields are its namespace, secret
  /// or not, so the scope serves them without an entitlement.
  private let scoped: ScopedSettings
  private let events: EventBus
  private let notifications: NotificationSink
  private let logger = Logger(label: "bluebubbles.ntfy")

  init(host: Host) {
    self.scoped = host.scopedSettings(for: Self.manifest)
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
    let topic = await scoped.own(NtfySettingsAdoption.Field.topic).trimmingCharacters(
      in: .whitespaces)
    // Not configured is not a failure. An ntfy-less install is the common one, and a sink
    // that declines every event is indistinguishable from a configured one that is failing.
    guard !topic.isEmpty else { return }

    // An unreadable Keychain answers empty, which here is treated as no token: ntfy accepts
    // unauthenticated publishes to a public topic, so the sink stays up rather than taking
    // the server down with it. The alert the store raises is what reports it.
    let token = await scoped.own(NtfySettingsAdoption.Field.token)

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

    await notifications.join(
      NtfyProvider(
        target: NtfyTarget(
          serverURL: await scoped.own(NtfySettingsAdoption.Field.server),
          topic: topic,
          accessToken: token.isEmpty ? nil : token,
          events: eventNames
        )
      ),
      on: events
    )
  }

  /// Leaves the shared lane rather than unregistering it: push may still be on it.
  func stop() async {
    await notifications.leave(providerID: NtfyProvider.identifier, from: events)
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
