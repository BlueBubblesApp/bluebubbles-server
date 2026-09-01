//  AppCapabilityTests
//  What narrowing the app layer actually bought.
//
//  `HandlerCapabilities` exists so a component states what it needs instead of taking the
//  whole `AppContext`. The HTTP controllers have worked that way since the beginning; the
//  SwiftUI app — the other consumer of the same interfaces layer — did not. It reached
//  `model.context` thirty-five times across thirteen view files, and `FirebaseSetupModel`
//  took an `AppContext?` on twelve methods while using exactly one member of it.
//
//  The test below is the point of the change rather than a check on it: driving the guided
//  Firebase model USED to require standing up a server, because that is what `AppContext?`
//  asks for. It now requires a two-line stub, and this file is where that stops being a
//  claim.

import BBHandlers
import BBInterfaces
import BBPersistence
import BBPushKit
import BBSettings
import BlueBubblesServerCore
import Testing

@testable import BlueBubblesApp

/// The whole of what the Firebase screen needs from a running server.
///
/// Two lines. `AppContext` has roughly forty-five members, opens two databases and starts a
/// service registry; none of that was ever reachable from this screen for a reason, and now
/// none of it is reachable at all.
private struct StubPushSetup: PushSetupProviding {
  let interface: PushInterface
  func pushInterface() async -> PushInterface { interface }
}

@Suite("App capabilities")
struct AppCapabilityTests {

  @Test("The Firebase setup model runs against a stub capability, with no server behind it")
  @MainActor
  func firebaseSetupNeedsOnlyPushSetup() async throws {
    let database = try AppDatabase.inMemory()
    let secrets = InMemorySecretStore()
    let interface = PushInterface(
      credentials: PushCredentialStore(secrets: secrets),
      settings: try await SettingsStore(database: database, secrets: secrets),
      // Unconfigured, which is exactly the state this screen exists to move a user out of.
      service: nil,
      deviceTokens: { [] },
      reloadPush: {}
    )

    let model = FirebaseSetupModel()
    #expect(model.status == nil)

    await model.refresh(push: StubPushSetup(interface: interface))

    let status = try #require(model.status)
    #expect(!status.isConfigured)
    #expect(!status.hasServiceAccount)
  }

  /// A nil capability is the app's ordinary state, not an error: the window opens before
  /// the server starts, and every screen has to render in that window.
  @Test("A nil capability leaves the model untouched rather than failing")
  @MainActor
  func nilCapabilityIsNormal() async {
    let model = FirebaseSetupModel()
    await model.refresh(push: nil)
    #expect(model.status == nil)
  }
}
