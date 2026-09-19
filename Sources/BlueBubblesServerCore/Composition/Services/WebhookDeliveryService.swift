//  WebhookDeliveryService
//  Registers the webhook sink so subscribed endpoints actually receive events.
//
//  It used to register the ntfy sink too, which meant ntfy's configuration sat in THIS
//  manifest's entitlements and ntfy stopped whenever webhooks were switched off. ntfy is
//  `NtfyDeliveryService` now; event sinks are additive by category, so two services is what
//  the model already expected.
//
//  It stopped being a `ConfigurableService` in the same change, and that is not a loss: the
//  only settings it ever watched were ntfy's. What a webhook IS lives in the `webhook` table,
//  not in settings, and the sink reads its targets per event so a registration added through
//  the API is delivered to without any restart at all.

import BBBuiltIns
import BBDiagnostics
import BBEvents
import BBInterfaces
import BBServiceKit
import BBSettings
import Logging

/// Registers the webhook sink so subscribed endpoints actually receive events.
///
/// Its own service rather than part of push, because the two are independent delivery routes
/// and a webhook-only install is a first-class deployment: several users run webhooks and no
/// Firebase at all.
actor WebhookDeliveryService: Service {
  static let manifest = BuiltInManifests.webhooks
  /// A failing endpoint is the endpoint's problem, not ours; the sink alerts once a
  /// failure becomes persistent and there is nothing here to restart.
  static let restartPolicy = RestartPolicy.never

  /// What this service touches, rather than the container that holds it.
  ///
  /// One narrower than it was: the notification sink and the settings store went with ntfy.
  typealias Host = any SettingsProviding & AlertProviding & CodecProviding & EventPublishing
    & WebhookAdministering

  private let alerts: AlertCenter
  private let codecs: CodecNegotiator
  private let events: EventBus
  /// The container rebuilds this per read from the same tracker and repository, so holding
  /// one is holding all of them.
  private let webhooks: WebhookDirectory
  private let logger = Logger(label: "bluebubbles.webhooks")

  init(host: Host) {
    self.alerts = host.alerts
    self.codecs = host.codecs
    self.events = host.events
    self.webhooks = host.webhooks
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

    let registered = await directory.targets().count
    logger.info("Webhook delivery ready", metadata: ["webhooks": .stringConvertible(registered)])
  }

  func stop() async {
    await events.unregister(.webhook)
  }

  var health: ServiceHealth {
    get async {
      let configured = await webhooks.targets().count
      guard configured > 0 else { return .inactive(reason: "no webhooks configured") }
      return .running
    }
  }
}
