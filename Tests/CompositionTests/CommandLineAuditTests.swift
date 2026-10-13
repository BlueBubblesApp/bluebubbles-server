//  CommandLineAuditTests
//  A command that changes the server and exits is recorded, as the operator at the command line.
//
//  `--clear-blocklist`, `--migrate` and `--import` run without building the server, so the
//  recorder the audit log service arms never existed for them: the blocklist could be cleared
//  and the configuration rewritten with nothing recorded. `source = cli` was declared and
//  documented and set by nothing.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAudit
import BBBuiltIns
import BBCore
import BBPersistence
import BBSettings
import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Command-line auditing")
struct CommandLineAuditTests {

  private func storage(auditLogOn: Bool) async throws -> (AppDatabase, SettingsStore) {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let settings = try await TestSettings.store(database: database)
    let disabled: Set<String> = auditLogOn ? [] : [BuiltInManifests.ID.auditLog.rawValue]
    try await settings.set(
      ServiceEnablement.serialized(disabled), forKey: Settings.disabledServicesKey)
    return (database, settings)
  }

  @Test("A setting a command writes is recorded as the operator, through the command line")
  func settingIsRecorded() async throws {
    let (database, settings) = try await storage(auditLogOn: true)
    let audit = await CommandLineAudit.begin(database: database, settings: settings)
    try await AuditContext.with(CommandLineAudit.context) {
      try await settings.set(Settings.socketPort, to: 1_234)
    }
    await audit.finish()

    let events = try await AuditRepository(database: database).page(limit: 10, offset: 0).events
    let change = try #require(events.first { $0.kind == .settingsChanged })
    #expect(change.actor == .operator)
    #expect(change.source == .cli)
    #expect(change.subject == .setting(Settings.socketPort.key))
  }

  @Test("Clearing the blocklist from the command line is recorded")
  func blocklistClearIsRecorded() async throws {
    let (database, settings) = try await storage(auditLogOn: true)
    let audit = await CommandLineAudit.begin(database: database, settings: settings)
    await AuditContext.with(CommandLineAudit.context) { audit.blocklistCleared(count: 3) }
    await audit.finish()

    let events = try await AuditRepository(database: database).page(limit: 10, offset: 0).events
    let cleared = try #require(events.first { $0.kind == .blocksCleared })
    #expect(cleared.source == .cli)
    #expect(cleared.metadata["count"] == .int(3))
  }

  @Test("With the audit log off, a command records nothing")
  func offRecordsNothing() async throws {
    let (database, settings) = try await storage(auditLogOn: false)
    let audit = await CommandLineAudit.begin(database: database, settings: settings)
    try await AuditContext.with(CommandLineAudit.context) {
      try await settings.set(Settings.socketPort, to: 1_234)
      audit.blocklistCleared(count: 3)
    }
    await audit.finish()
    #expect(try await AuditRepository(database: database).count() == 0)
  }
}
