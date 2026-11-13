//  BuiltInManifests+Sinks
//  The event sinks: webhooks, ntfy and push notifications.
//
//  Its own file because the three are the contrast that makes the tunnels' exclusive
//  category worth modelling: all of them are expected to run at once, so enabling one never
//  disables another. The identifiers and the list of every built-in stay in
//  `BuiltInManifests.swift`.

import BBServiceKit
import BBSettings

extension BuiltInManifests {

  // MARK: - Event sinks
  //
  // The contrast that makes exclusivity worth modelling: these are all expected to run at
  // once, so the category is additive and enabling one does not disable another.

  public static let webhooks = ServiceManifest(
    id: ID.webhooks,
    name: "Webhooks",
    summary: "POST server events to your own endpoints.",
    details: "Every event this server produces can be sent to a URL you control.",
    category: .eventSink,
    entitlements: [
      .receiveEvents(names: []),
      .network(hosts: ["*"]),
    ]
  )

  /// ntfy, as its own service rather than the second half of the webhook one.
  ///
  /// It was registered by `WebhookDeliveryService`, which meant its configuration lived in
  /// the WEBHOOK manifest's entitlements and its only switch was the webhook switch: turning
  /// webhooks off stopped ntfy, and there was no way to run one without the other. They are
  /// independent delivery routes — several people run ntfy and no webhooks at all — and the
  /// category exists to hold exactly that: event sinks are additive, so nothing about the two
  /// being separate forces a choice between them.
  ///
  /// Its configuration is manifest FIELDS rather than the four core `ntfy_*` settings it
  /// used to be, so it is edited where every other integration is edited. Those four keys
  /// still exist and are read once, by the composition root before any service starts, to
  /// adopt what an existing install already had; `NtfySettingsAdoption` says why that is
  /// neither a `FieldMigration` nor this service's job.
  public static let ntfy = ServiceManifest(
    id: ID.ntfy,
    name: "ntfy",
    summary: "Publish events to an ntfy topic.",
    details: """
      ntfy delivers a readable notification to your phone or desktop without Firebase and \
      without an account. Publish to a topic on ntfy.sh, or to your own server if you \
      self-host one.
      """,
    category: .eventSink,
    symbol: "bell.badge",
    version: "1.0.0",
    entitlements: [
      .receiveEvents(names: []),
      // Any host: self-hosting is the ordinary case, so the server URL is whatever the
      // person typed and cannot be named here.
      .network(hosts: ["*"]),
    ],
    settings: [
      .header("Topic"),
      .paragraph(
        "Anyone who knows a topic name can read it and publish to it, so pick something "
          + "hard to guess. Subscribe to the same topic in the ntfy app to receive these "
          + "notifications."
      ),
      .field(
        FieldDescriptor(
          key: "topic",
          label: "Topic",
          help: "Leave empty to publish nothing.",
          kind: .text(placeholder: "my-bluebubbles-a7f3"),
          isConfidential: true,
          isRequired: true
        )),
      .field(
        FieldDescriptor(
          key: "server",
          label: "Server",
          help: "Change this only if you self-host ntfy.",
          kind: .url
        )),
      .field(
        FieldDescriptor(
          key: "token",
          label: "Access Token",
          help: "Only needed for a protected topic.",
          kind: .text(placeholder: "tk_…"),
          isSecret: true
        )),

      .divider,
      .header("Events"),
      .paragraph(
        "ntfy's whole purpose is a notification somebody reads, so this matters more here "
          + "than it does for a webhook: everything means every typing indicator and every "
          + "location update buzzes your phone."
      ),
      .field(
        FieldDescriptor(
          key: "events",
          label: "Send",
          kind: .eventSubscription
        )),
    ]
  )

  public static let push = ServiceManifest(
    id: ID.push,
    name: "Push Notifications",
    summary: "Deliver notifications while the client app is closed.",
    details: """
      Uses Firebase Cloud Messaging. Entirely optional: without it clients still receive \
      everything while they are open.
      """,
    category: .eventSink,
    entitlements: [
      .receiveEvents(names: []),
      .network(hosts: [
        "fcm.googleapis.com", "firestore.googleapis.com",
        "oauth2.googleapis.com", "firebaserules.googleapis.com",
      ]),
      // `remote_restart_enabled` and `last_fcm_restart` have no presentation, so the
      // permissions sentence names them by their storage keys. That is the honest answer:
      // a setting a service reads is a setting a person is entitled to see on its
      // permissions list, and an ugly name is a better outcome than an undeclared read.
      // `last_fcm_restart` is also written: it is this service's own bookkeeping, and a
      // write it never declared would be exactly the hijack the model exists to surface.
      .readSettings(keys: [
        Settings.serverAddress.key, Settings.remoteRestartEnabled.key, Settings.lastFcmRestart.key,
      ]),
      .writeSettings(keys: [Settings.lastFcmRestart.key]),
    ]
  )
}
