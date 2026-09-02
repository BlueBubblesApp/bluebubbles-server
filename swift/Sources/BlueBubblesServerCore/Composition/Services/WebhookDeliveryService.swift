//  WebhookDeliveryService
//  Registers the webhook and ntfy sinks so subscribed endpoints actually receive events.

import BBEvents
import BBServiceKit
import BBSettings

/// Registers the webhook sink so subscribed endpoints actually receive events.
///
/// Its own service rather than part of push, because the two are independent delivery routes
/// and a webhook-only install is a first-class deployment — several users run ntfy and no
/// Firebase at all. `WebhookSink` had been written, tested and never constructed, so every
/// webhook subscription in the database was inert.
actor WebhookDeliveryService: ContextualService, ConfigurableService {
  static let manifest = BuiltInManifests.webhooks
  /// A failing endpoint is the endpoint's problem, not ours; the sink alerts once a
  /// failure becomes persistent and there is nothing here to restart.
  static let restartPolicy = RestartPolicy.never

  let context: AppContext

  init(host: AppContext) { self.context = host }

  static let watchedSettings: Set<String> = [
    Settings.ntfyTopic.key, Settings.ntfyServer.key, Settings.ntfyToken.key,
    Settings.ntfyEvents.key,
  ]

  func start() async throws {
    // Targets are read per event rather than captured: a webhook added through the API
    // has to start receiving without a restart, which a snapshot taken here would not.
    await context.events.register(
      WebhookSink(
        targets: { [weak context] in await context?.webhooks.targets() ?? [] },
        negotiator: context.codecs,
        alerts: context.alerts,
        // Shared with the context so delivery history outlives a restart of this
        // service, and so the settings page has something to read.
        deliveries: context.webhookDeliveries
      )
    )

    // ntfy is registered only when a topic is configured. An unconfigured sink that
    // declines every event is indistinguishable from a configured one that is failing,
    // and it is the second state an operator needs to be able to see.
    let topic = await context.settings.get(Settings.ntfyTopic)
      .trimmingCharacters(in: .whitespaces)
    guard !topic.isEmpty else { return }

    // An unreadable Keychain gives nil, which here is treated as no token: ntfy accepts
    // unauthenticated publishes to a public topic, so the sink stays up rather than
    // taking the server down with it. The alert raised by the store is what reports it.
    let token = await context.settings.secret(Settings.ntfyToken)?.unsafeStringValue() ?? ""

    // The event filter `NtfyTarget` has always supported and nothing ever supplied, so
    // every ntfy install has been receiving the wildcard whether or not that is what the
    // operator wanted. An empty or absent setting still means everything, which is what
    // existing installs already get.
    let events = await context.settings.get(Settings.ntfyEvents)
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    // Cleared to nothing means nothing, not everything. The setting ships as `*`, so an
    // empty value is someone deliberately unticking every box — and a sink registered to
    // accept no event is the inert-but-present state this project keeps finding, so it is
    // not registered at all. The settings row says so where the boxes are unticked.
    guard !events.isEmpty else { return }

    await context.events.register(
      NtfySink(
        target: NtfyTarget(
          serverURL: await context.settings.get(Settings.ntfyServer),
          topic: topic,
          accessToken: token.isEmpty ? nil : token,
          events: events
        )
      )
    )
  }

  func stop() async {
    await context.events.unregister(.webhook)
    await context.events.unregister(.ntfy)
  }

  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      let webhooks = await context.webhooks.targets().count
      // A topic subscribed to no events delivers nothing, so it does not count as
      // configured — reporting "running" for it would describe a sink that was never
      // registered.
      let topic = await context.settings.get(Settings.ntfyTopic)
      let ntfyEvents = await context.settings.get(Settings.ntfyEvents)
      let ntfy =
        !topic.isEmpty
        && !ntfyEvents.trimmingCharacters(in: .whitespaces).isEmpty
      guard webhooks > 0 || ntfy else {
        return .inactive(reason: "no webhooks or ntfy topic configured")
      }
      return .running
    }
  }
}
