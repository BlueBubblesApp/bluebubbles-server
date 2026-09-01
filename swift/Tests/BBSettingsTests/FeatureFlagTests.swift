//  FeatureFlagTests
//  The properties that make a feature flag a feature flag rather than a setting.
//
//  Everything here is a claim the rest of the codebase relies on: that a flag ships off, that
//  its key is recognisable, that it reaches the settings screen without a second edit, and
//  that it carries a reason someone can read. Each of those is exactly the sort of thing that
//  is true when written and quietly stops being true four flags later.

import Foundation
import GRDB
import Testing

@testable import BBPersistence
@testable import BBSettings

@Suite("Feature flags")
struct FeatureFlagTests {

  /// The property the whole idea rests on. A flag that shipped on by accident is
  /// indistinguishable from a feature, and for the route-mounting flags it would also make
  /// the default route table differ from the previous server's.
  @Test("Every flag is off by default")
  func allDefaultOff() {
    for flag in Features.all {
      #expect(
        flag.setting.defaultValue == false,
        "\(flag.id) ships enabled — a flag that defaults on is not a flag"
      )
    }
  }

  @Test("Keys are prefixed and unique")
  func keysAreWellFormed() {
    let keys = Features.all.map(\.key)
    #expect(Set(keys).count == keys.count, "two flags share a key")

    for flag in Features.all {
      #expect(flag.key == "feature_\(flag.id)")
      // The prefix is what makes a flag recognisable in an exported config and in a
      // support conversation without cross-referencing anything.
      #expect(flag.key.hasPrefix("feature_"))
    }
  }

  @Test("Ids are unique and lookup finds them")
  func identifiersResolve() {
    let ids = Features.all.map(\.id)
    #expect(Set(ids).count == ids.count)

    for flag in Features.all {
      #expect(Features.flag(id: flag.id) == flag)
    }
    #expect(Features.flag(id: "not-a-flag") == nil)
  }

  /// A flag whose reason lives only in a code comment gets turned on by someone who never
  /// read it. The rationale is shown in the settings screen, returned by the status
  /// endpoint, and put into the 403 when a route refuses — so it has to exist and has to
  /// be a sentence rather than a label.
  @Test("Every flag explains itself")
  func flagsCarryAReason() {
    for flag in Features.all {
      #expect(!flag.summary.isEmpty, "\(flag.id) has no summary")
      #expect(
        flag.rationale.count > 40,
        "\(flag.id)'s rationale is too short to explain anything: '\(flag.rationale)'"
      )
    }
  }

  /// Declared once, reached everywhere. If a flag has to be added to `allKeys` by hand it
  /// will eventually not be, and a key missing from that list does not migrate.
  @Test("Flags are declared settings")
  func flagsAreInTheRegistry() {
    for flag in Features.all {
      #expect(
        Settings.allKeys.contains(flag.key),
        "\(flag.key) is not in Settings.allKeys, so it will not migrate"
      )
      #expect(
        Settings.renderable.contains { $0.key == flag.key },
        "\(flag.key) has no row in the settings screen"
      )
    }
  }

  /// Every flag renders as a toggle with help text, because the generated settings screen
  /// has no other way to show a boolean and no other place to put the reason.
  @Test("Flags present as toggles with their reason as help")
  func presentation() {
    for flag in Features.all {
      let presentation = flag.setting.presentation
      #expect(presentation != nil, "\(flag.id) has no presentation")
      if case .toggle = presentation?.control {
      } else {
        Issue.record("\(flag.id) is not a toggle")
      }
      #expect(presentation?.help == flag.rationale)
      #expect(presentation?.label == flag.summary)
    }
  }

  /// Reading goes through the ordinary settings layers, which is what lets a flag be forced
  /// on for one run from the command line without persisting it — the intended way to try
  /// one before committing to it.
  @Test("A flag reads off by default and honours a command-line override")
  func readingThroughTheStore() async throws {
    let flag = Features.findMy

    let store = try await Self.makeStore()
    #expect(await store.isEnabled(flag) == false)
    #expect(await store.featureStates()[flag] == false)

    let overridden = try await Self.makeStore(commandLine: [flag.key: "true"])
    #expect(await overridden.isEnabled(flag))
    #expect(await overridden.featureStates()[flag] == true)
  }

  @Test("featureStates covers every declared flag")
  func statesAreComplete() async throws {
    let store = try await Self.makeStore()
    let states = await store.featureStates()
    #expect(states.count == Features.all.count)
    for flag in Features.all {
      #expect(states[flag] != nil, "\(flag.id) is missing from the capability report")
    }
  }

  private static func makeStore(
    commandLine: [String: String] = [:]
  ) async throws -> SettingsStore {
    let database = try AppDatabase.inMemory()
    return try await SettingsStore(
      database: database,
      secrets: InMemorySecretStore(),
      commandLineValues: commandLine
    )
  }
}
