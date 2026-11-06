//  RetiredProxyAlertMigrationTests
//  `interfaces.deleteRetiredProxyAlerts` removes exactly the alerts no method can withdraw.
//
//  An alert saved under a dedupe key a connection method no longer writes is reloaded at
//  start for its whole retention window, and nothing dismisses it, because a method withdraws
//  by the `proxy/<service id>/` prefix. The migration deletes the five retired shapes. The
//  danger is the other direction: `BBProxy`'s error codes also begin `proxy.`, and they are
//  raised as dedupe keys today, so these assert that every current spelling survives.

import BBAppStore
import BBBuiltIns
import BBPersistence
import BBProxy
import BlueBubblesServerCore
import Foundation
import GRDB
import Testing

@Suite("Retired proxy alert keys")
struct RetiredProxyAlertMigrationTests {

  /// `InterfacesSchema` as it stood before the cleanup: the same tables, without
  /// `registerSchema`, so a database can be stopped just short of the migration under test.
  private enum InterfacesBeforeCleanup: SchemaContributor {
    static let schemaNamespace = InterfacesSchema.schemaNamespace
    static let legacyMigrationIdentifiers = InterfacesSchema.legacyMigrationIdentifiers
    static func registerSchemaBeforeTimestampRename(in migrator: inout DatabaseMigrator) {
      InterfacesSchema.registerSchemaBeforeTimestampRename(in: &migrator)
    }
  }

  private static let ngrok = BuiltInManifests.ID.proxyNgrok

  /// One of each shape the methods wrote before every key moved under one prefix.
  private static let retired = [
    "proxy.app.bluebubbles.proxy.ngrok.auth-token-missing",
    "proxy.binary-missing.app.bluebubbles.proxy.ngrok",
    "proxy.attention.app.bluebubbles.proxy.zrok.reserve-name",
    "proxy.gave-up.app.bluebubbles.proxy.cloudflare",
    "app.bluebubbles.proxy.tailscale.address-not-saved",
  ]

  /// What is written today and must outlive the migration.
  private static var current: [String] {
    let proxyKeys: [ProxyAttentionAlerts.Key] = [
      .refusal("auth-token-missing"), .step("reserve-name"), .toolMissing, .gaveUp,
      .addressNotSaved,
    ]
    let errors: [ProxyError] = [
      .notConfigured(""), .tunnelFailed(reason: ""), .addressUnavailable, .pending(reason: ""),
    ]
    return proxyKeys.map { $0.dedupeKey(for: ngrok) } + errors.map(\.dedupeKey)
      + ["tool.install.ngrok", "service.\(ngrok.rawValue)"]
  }

  @Test("Upgrading deletes every retired proxy key and nothing else")
  func deletesOnlyRetiredKeys() async throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(configuration: configuration)
    try AppDatabase(queue: queue).migrate(contributors: [InterfacesBeforeCleanup.self])

    let keys = Self.retired + Self.current
    try await queue.write { db in
      for key in keys {
        try db.execute(
          sql: """
            INSERT INTO alert
              (uuid, severity, title, body, source, dedupe_key, created_at, last_occurred_at)
            VALUES (?, 'warning', 'Title', 'Body', 'Test', ?, ?, ?)
            """,
          arguments: [UUID().uuidString, key, Date(), Date()])
      }
    }

    try AppDatabase(queue: queue).migrate(contributors: [InterfacesSchema.self])

    let remaining = try await queue.read { db in
      try String.fetchAll(db, sql: "SELECT dedupe_key FROM alert")
    }
    #expect(Set(remaining) == Set(Self.current))
  }
}
