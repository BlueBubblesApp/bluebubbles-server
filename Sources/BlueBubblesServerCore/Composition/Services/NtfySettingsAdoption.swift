//  NtfySettingsAdoption
//  Moving an existing install's ntfy configuration into the ntfy integration, once.
//
//  ntfy's configuration used to be four core settings (`ntfy_topic`, `ntfy_server`,
//  `ntfy_events`, `ntfy_token`) and is now four manifest fields in the service's own
//  namespace. An install that had ntfy working must not come up silently publishing nothing
//  because its topic moved.
//
//  ## Why this is not a `FieldMigration`
//
//  Because it cannot be one, and that is the design holding rather than a gap in it.
//  `ServiceMigrator.apply` assembles every key from the manifest's own namespace
//  specifically so a migration cannot reach another service's settings or the core ones —
//  the old keys are core. `ServiceMigration.swift` says where work like this belongs:
//  "anything requiring real computation belongs in the service's own `start`, where it can
//  report a reason and be tested". This is that, and this file is the "be tested" half: a
//  free function over a store rather than a method on an actor that needs a whole `Host`
//  built to call it.
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

    try await store.set(legacyTopic, forKey: key(Field.topic), isSecret: false)
    if let server = await store.string(forKey: Settings.ntfyServer.key), !server.isEmpty {
      try await store.set(server, forKey: key(Field.server), isSecret: false)
    }
    if let events = await store.string(forKey: Settings.ntfyEvents.key), !events.isEmpty {
      try await store.set(events, forKey: key(Field.events), isSecret: false)
    }
    // Written AS A SECRET. Carried across as a plain row it would be a downgrade in storage
    // nobody asked for, and the same failure `LegacyConfigMigration` exists to avoid.
    if let token = await store.secret(Settings.ntfyToken)?.unsafeStringValue(), !token.isEmpty {
      try await store.set(token, forKey: key(Field.token), isSecret: true)
    }

    // Cleared LAST, after the values are safely in the new namespace, so a failure part-way
    // through leaves the old configuration intact and this runs again next start.
    try await store.set("", forKey: Settings.ntfyTopic.key, isSecret: false)
    try await store.set("", forKey: Settings.ntfyToken.key, isSecret: true)
    return true
  }
}
