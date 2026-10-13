//  NtfySettingsAdoption
//  Moving an existing install's ntfy configuration into the ntfy integration, once.
//
//  ntfy's configuration used to be four core settings (`ntfy_topic`, `ntfy_server`,
//  `ntfy_events`, `ntfy_token`) and is now four manifest fields in the service's own
//  namespace. An install that had ntfy working must not come up silently publishing nothing
//  because its topic moved.
//
//  ## Why the composition root runs it, and not the service
//
//  It cannot be a `FieldMigration`: `ServiceMigrator.apply` assembles every key from the
//  manifest's own namespace specifically so a migration cannot reach another service's
//  settings or the core ones, and the old keys are core. Nor can `NtfyDeliveryService` do
//  it: the old token is a core SECRET, which no manifest may declare, so a service doing
//  this has to hold the raw store, and no service is handed one (`ScopedSettingsProviding`).
//  Moving core settings into a namespace is the host's work, so it runs in
//  `ServerComposition.prepareServiceSettings` beside the field migrations, before any
//  service reads its settings, and as ntfy in the audit log because it is ntfy's data.
//
//  See `NtfySettingsAdoptionTests`, and `Sources/BlueBubblesApp/CLAUDE.md`.

import BBServiceKit
import BBSettings
import Foundation

enum NtfySettingsAdoption {

  /// The manifest's field keys. Spelled once, here, and read by the service from the same
  /// place: a typo on either side reads as "not configured" rather than as an error, which
  /// is the quietest way for this to break.
  enum Field {
    static let topic = "topic"
    static let server = "server"
    static let token = "token"
    static let events = "events"
  }

  /// Adopts the legacy configuration if there is one and the integration has none.
  ///
  /// Guarded on the TOPIC, on both sides. A topic is what makes an ntfy configuration exist
  /// at all, so "the integration has none and the old key has one" is exactly the state that
  /// needs adopting; and a topic already in the new namespace is the person's own, which an
  /// adoption must fill a gap around rather than overwrite.
  ///
  /// - Returns: whether anything was moved, so the caller can log it.
  @discardableResult
  static func run(store: SettingsStore, manifest: ServiceManifest) async throws -> Bool {
    func key(_ field: String) -> String { manifest.storageKey(for: field) }

    let existing = await store.string(forKey: key(Field.topic)) ?? ""
    guard existing.isEmpty else { return false }

    let legacyTopic = await store.string(forKey: Settings.ntfyTopic.key) ?? ""
    guard !legacyTopic.trimmingCharacters(in: .whitespaces).isEmpty else { return false }

    // Read before the write, because the batch body cannot await.
    let server = await store.string(forKey: Settings.ntfyServer.key) ?? ""
    let events = await store.string(forKey: Settings.ntfyEvents.key) ?? ""
    let token = await store.secret(Settings.ntfyToken)?.unsafeStringValue() ?? ""

    // ONE batch: the new fields and the clearing of the old ones commit together or not at
    // all. Written one at a time, the topic landed first, and the guard above reads exactly
    // that topic: a failure on any later write (the token's Keychain write is the likely one)
    // left an adoption that could never be retried, with the server, the events and the
    // credential stranded under keys nothing reads any more.
    try await store.write { batch in
      batch.setDynamic(legacyTopic, forKey: key(Field.topic), isSecret: false)
      if !server.isEmpty {
        batch.setDynamic(server, forKey: key(Field.server), isSecret: false)
      }
      if !events.isEmpty {
        batch.setDynamic(events, forKey: key(Field.events), isSecret: false)
      }
      // Written AS A SECRET. Carried across as a plain row it would be a downgrade in storage
      // nobody asked for, and the same failure `LegacyConfigMigration` exists to avoid.
      if !token.isEmpty {
        batch.setDynamic(token, forKey: key(Field.token), isSecret: true)
      }
      // Cleared in the same batch, so the old configuration is gone exactly when the new one
      // exists, and a batch that fails leaves both as they were for the next start to retry.
      batch.setDynamic("", forKey: Settings.ntfyTopic.key, isSecret: false)
      batch.setDynamic("", forKey: Settings.ntfyToken.key, isSecret: true)
    }
    return true
  }
}
