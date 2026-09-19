//  HandOffIdentityTests
//  A finished hand-off watcher forgets ITSELF, never whoever replaced it.
//
//  The watcher's last act is to remove its own entry, and it does that after an actor hop.
//  `beginHandOff` for the same call in that window replaces the entry, so the finished task
//  removed and CANCELLED its own replacement. Nothing was left admitting the joiner, and the
//  Mac stayed in the call until the five-minute timeout: a silent failure of the one feature
//  whose job is getting the Mac out of a call it does not belong in.
//
//  `protectedCalls` is the observable side of the same map, and it carries a second
//  consequence: `FaceTimeCleanup` reads it to decide which calls it must NOT leave. A call
//  whose watcher was wrongly forgotten stops being protected, so the sweep can hang up on a
//  conversation a client is mid-way through joining.

import BBBuiltIns
import BBPersistence
import BBPrivateAPIContract
import BBServiceKit
import BBSettings
import BBTestSupport
import Foundation
import Logging
import Testing

@testable import BBFaceTime
@testable import BlueBubblesServerCore

@Suite("Hand-off identity")
struct HandOffIdentityTests {

  private func coordinator() async throws -> FaceTimeCoordinator {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let settings = try await SettingsStore(database: database, secrets: InMemorySecretStore())
    return FaceTimeCoordinator(
      settings: settings,
      privateAPI: { nil },
      logger: Logger(label: "test")
    )
  }

  private var api: FailingPrivateAPI { FailingPrivateAPI() }

  @Test("Re-registering a call keeps exactly one protected entry")
  func reRegisteringKeepsOneEntry() async throws {
    let coordinator = try await coordinator()

    await coordinator.beginHandOff(api: api, callUUID: "CALL-1", conversationUUID: "CONV-1")
    await coordinator.beginHandOff(api: api, callUUID: "CALL-1", conversationUUID: "CONV-1")

    #expect(await coordinator.protectedCalls == ["CALL-1"])
  }

  @Test("A replaced watcher finishing does not unprotect the call")
  func replacedWatcherDoesNotUnprotect() async throws {
    // The race, driven deterministically: the API refuses everything, so the first watcher's
    // run ends almost immediately and reaches its trailing cleanup while a second
    // registration for the same call is already in place.
    let coordinator = try await coordinator()

    await coordinator.beginHandOff(api: api, callUUID: "CALL-2", conversationUUID: "CONV-2")
    await coordinator.beginHandOff(api: api, callUUID: "CALL-2", conversationUUID: "CONV-2")

    try await Task.sleep(for: .milliseconds(250))

    // Before the fix the first task's cleanup removed and cancelled the SECOND, leaving the
    // call unprotected and unwatched.
    #expect(
      await coordinator.protectedCalls.contains("CALL-2"),
      "a finished watcher must not forget the run that replaced it"
    )
  }

  @Test("An explicit end still forgets the call")
  func explicitEndStillWorks() async throws {
    // The identity check is only for a watcher forgetting ITSELF. An explicit `endHandOff`
    // is a caller saying "stop watching this", and must cancel whatever is current.
    let coordinator = try await coordinator()

    await coordinator.beginHandOff(api: api, callUUID: "CALL-3", conversationUUID: "CONV-3")
    #expect(await coordinator.protectedCalls.contains("CALL-3"))

    await coordinator.endHandOff(callUUID: "CALL-3")
    #expect(await coordinator.protectedCalls.isEmpty)
  }

  @Test("Stopping clears every watcher")
  func stopClearsEverything() async throws {
    let coordinator = try await coordinator()

    for index in 0..<3 {
      await coordinator.beginHandOff(
        api: api, callUUID: "CALL-\(index)", conversationUUID: "CONV-\(index)")
    }
    #expect(await coordinator.protectedCalls.count == 3)

    await coordinator.stop()
    #expect(await coordinator.protectedCalls.isEmpty)
  }

  @Test("Different calls do not interfere")
  func distinctCallsAreIndependent() async throws {
    let coordinator = try await coordinator()

    await coordinator.beginHandOff(api: api, callUUID: "A", conversationUUID: "CONV-A")
    await coordinator.beginHandOff(api: api, callUUID: "B", conversationUUID: "CONV-B")
    await coordinator.endHandOff(callUUID: "A")

    #expect(await coordinator.protectedCalls == ["B"])
  }
}
