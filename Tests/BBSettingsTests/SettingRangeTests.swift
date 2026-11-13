//  SettingRangeTests
//  A range a number control shows is a range the server enforces, on every path.
//
//  `socket_port` declared `1...65535` for the stepper and nowhere else, so a write through the
//  API, `--set socket_port=70000` and the config file all took any integer, and the listener
//  then failed to bind with nothing having refused the value. The same was true of three
//  other number settings, and the override layers bypassed even the ranges that WERE enforced.

import BBPersistence
import Foundation
import Testing

@testable import BBSettings

@Suite("Setting ranges")
struct SettingRangeTests {

  private func store(commandLine: [String: String] = [:], configFile: [String: String] = [:])
    async throws -> SettingsStore
  {
    try await SettingsStore(
      database: try AppDatabase.inMemory(contributors: [SettingsSchema.self]),
      secrets: InMemorySecretStore(),
      configFileValues: configFile,
      commandLineValues: commandLine
    )
  }

  @Test("A write outside a number control's range is refused")
  func writeOutsideRangeIsRefused() async throws {
    let settings = try await store()
    await #expect(throws: SettingsError.self) { try await settings.set(Settings.socketPort, to: 0) }
    await #expect(throws: SettingsError.self) {
      try await settings.set(Settings.socketPort, to: 70_000)
    }
    try await settings.set(Settings.socketPort, to: 4321)
    #expect(await settings.get(Settings.socketPort) == 4321)
  }

  @Test("An override outside the range is passed over for the next layer")
  func overrideOutsideRangeIsIgnored() async throws {
    let settings = try await store(
      commandLine: [Settings.socketPort.key: "70000"],
      configFile: [Settings.socketPort.key: "5555"])
    // The config file's value, which is in range, rather than the command line's.
    #expect(await settings.resolve(Settings.socketPort).value == 5555)
    #expect(await settings.resolve(Settings.socketPort).source == .configFile)

    let unparsable = try await store(commandLine: [Settings.socketPort.key: "not a port"])
    #expect(await unparsable.resolve(Settings.socketPort).source == .declaredDefault)
  }

  @Test("An override inside the range applies as before")
  func overrideInsideRangeApplies() async throws {
    let settings = try await store(commandLine: [Settings.socketPort.key: "1234"])
    #expect(await settings.resolve(Settings.socketPort).source == .commandLine)
  }

  /// The other half, and the reason only the RANGE binds an override. The password's entropy
  /// rule is a set-time policy: a config file or `--set` carrying a weak legacy password must
  /// keep working, or every client of that server is locked out.
  @Test("A weak password override still applies")
  func weakPasswordOverrideApplies() async throws {
    let settings = try await store(commandLine: [Settings.password.key: "abc"])
    #expect(await settings.resolve(Settings.password).source == .commandLine)
  }

  @Test("Every number setting's default is inside its own range")
  func defaultsAreInRange() {
    // A default outside the range would be refused the first time anyone wrote it back.
    for setting in Settings.all {
      guard case .number(_?) = setting.presentation.control else { continue }
      #expect(setting.hasValidator, "\(setting.key) shows a range and enforces none")
    }
    #expect(Settings.socketPort.rangeViolation(Settings.socketPort.defaultValue) == nil)
    #expect(
      Settings.faceTimeLinkTTLHours.rangeViolation(Settings.faceTimeLinkTTLHours.defaultValue)
        == nil)
    #expect(
      Settings.chatDatabaseReaders.rangeViolation(Settings.chatDatabaseReaders.defaultValue)
        == nil)
    #expect(Settings.autoInstallHour.rangeViolation(Settings.autoInstallHour.defaultValue) == nil)
    #expect(Settings.dbPollInterval.rangeViolation(Settings.dbPollInterval.defaultValue) == nil)
    #expect(Settings.startDelay.rangeViolation(Settings.startDelay.defaultValue) == nil)
  }
}
