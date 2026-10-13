//  HomeDetailTests
//  Home's depth: Basic until a store says otherwise, and the choice survives a relaunch.
//
//  The value is mirrored on `HomeModel` and persisted as `Settings.homeDetail`, the shape
//  `OnboardingModel` uses. What can go wrong is the seam: seeding writing the value straight
//  back, a store that was never attached losing the choice, or a stored spelling nobody
//  recognises taking the page down with it.

import BBPersistence
import BBSettings
import BBTestSupport
import Testing

@testable import BlueBubblesApp

@Suite("Home detail")
@MainActor
struct HomeDetailTests {

  private static func store() async throws -> SettingsStore {
    try await TestSettings.store()
  }

  @Test("Basic on a server that has never been asked")
  func defaultsToBasic() async throws {
    let model = HomeModel()
    #expect(model.detail == .basic)
    await model.attach(try await Self.store())
    #expect(model.detail == .basic)
  }

  @Test("A change is stored, and the next attach reads it back")
  func roundTrips() async throws {
    let store = try await Self.store()
    let first = HomeModel()
    await first.attach(store)
    first.detail = .advanced
    // The write is a task of its own; give it the turn.
    try await waitUntil("the detail to be stored") {
      await store.get(Settings.homeDetail) == "advanced"
    }
    #expect(await store.get(Settings.homeDetail) == "advanced")

    let second = HomeModel()
    await second.attach(store)
    #expect(second.detail == .advanced)
  }

  @Test("A stored spelling this build does not know reads as Basic")
  func unknownSpellingIsBasic() async throws {
    let store = try await Self.store()
    try await store.set(Settings.homeDetail, to: "everything")
    let model = HomeModel()
    await model.attach(store)
    #expect(model.detail == .basic)
  }

  @Test("Clearing what Home has read keeps the depth")
  func clearKeepsDetail() {
    let model = HomeModel()
    model.detail = .advanced
    model.clear()
    #expect(model.detail == .advanced)
  }
}
