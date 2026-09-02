//  SettingApplicationTests
//  The settings that need a restart are declared as such, not listed elsewhere.

import Foundation
import Testing

@testable import BBSettings

@Suite("Setting application")
struct SettingApplicationTests {

  /// The five composition-time settings, plus every feature flag. A change to this set is a
  /// change to which edits raise the "restart to apply" notice, so it is pinned.
  @Test("Composition-time settings are exactly the ones the composition root reads once")
  func compositionSettings() {
    let composition = Set(Settings.all.filter { $0.application == .composition }.map(\.key))
    let expected =
      Set([
        Settings.authMode.key, Settings.additiveEndpoints.key,
        Settings.eventPayloadCodec.key, Settings.faceTimeIncomingHandoff.key,
        Settings.chatDatabaseReaders.key,
      ]).union(Features.allKeys)
    #expect(composition == expected)
  }

  @Test("Every declared setting is in allKeys exactly once")
  func allKeysIsDerived() {
    let keys = Settings.allKeys
    #expect(Set(keys).count == keys.count)
    for setting in Settings.renderable {
      #expect(keys.contains(setting.key))
    }
    for setting in Settings.hidden {
      #expect(keys.contains(setting.key))
      #expect(setting.presentation.isInternal, "\(setting.key) is internal but renders")
    }
  }

  /// The Electron-only rows stay reserved and stay hidden.
  @Test("Legacy settings are declared, migrate, and never render")
  func legacySettingsAreReservedButHidden() {
    let renderable = Set(Settings.renderable.map(\.key))
    #expect(Settings.Legacy.all.count == 8)
    for key in Settings.Legacy.all.map(\.key) {
      #expect(Settings.allKeys.contains(key), "\(key) would not migrate")
      #expect(!renderable.contains(key), "\(key) is legacy and must not render")
    }
  }
}
