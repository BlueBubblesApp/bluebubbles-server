//  PrivateAPIObservationTests
//  The Private API runtime is followed from the composition being started, not from
//  `AppModel.server`.
//
//  The health follow starts before the services do, and `server` is assigned only once every
//  service is up, so every snapshot the registry published during a start re-resolved the
//  runtime through a server that was not there yet. The settings page then said the Private
//  API was switched off on a server where it was running, until some unrelated service
//  happened to change health. These hold the follow to what it is handed.
//
//  A switched-off runtime opens no socket, which is what lets a test start one.

import BBPrivateAPI
import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Private API observation")
@MainActor
struct PrivateAPIObservationTests {

  private static func runtime() -> PrivateAPIRuntime {
    PrivateAPIRuntime(
      configuration: PrivateAPIConfiguration(
        isEnabled: false,
        socketPath: NSTemporaryDirectory() + "bb-observe-\(UUID().uuidString.prefix(8)).sock"
      )
    )
  }

  @Test("The runtime is followed while the model holds no server yet")
  func followsBeforeTheServerIsAssigned() async throws {
    let model = AppModel()
    let runtime = Self.runtime()
    #expect(model.server == nil)

    await model.syncPrivateAPIRuntime { runtime }
    try await waitUntil("the runtime's state to reach the model") {
      model.privateAPIState == .init(outcome: .notStarted, isConnected: false)
    }

    // And followed, not read once: what the runtime publishes next reaches the page.
    try await runtime.start()
    try await waitUntil("the runtime's next state to reach the model") {
      model.privateAPIState?.outcome == .disabled
    }

    await model.stopFollowingServer()
    #expect(model.privateAPIState == nil)
    #expect(model.followedPrivateAPIRuntime == nil)
  }

  @Test("A withdrawn runtime stops being followed and clears what it showed")
  func withdrawnRuntimeClears() async throws {
    let model = AppModel()
    let runtime = Self.runtime()
    await model.syncPrivateAPIRuntime { runtime }
    try await waitUntil("the runtime's state to reach the model") {
      model.privateAPIState != nil
    }

    await model.syncPrivateAPIRuntime { nil }
    #expect(model.privateAPIState == nil)
    #expect(!model.follows.following.contains(.privateAPIRuntime))
    await model.stopFollowingServer()
  }
}
