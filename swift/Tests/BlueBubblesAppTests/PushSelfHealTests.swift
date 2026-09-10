//  PushSelfHealTests
//  Configured, but not running, is a state the user must not have to restart the server out of.
//
//  `PushDeliveryService.canRun` reads the Keychain once, at startup, and `isConfigured()`
//  swallows a read that FAILS as "there are no credentials". A first launch prompts for
//  Keychain access: a build without the `keychain-access-groups` entitlement falls back to
//  the legacy store, which prompts rather than refusing, so the gate can lose that race and
//  decline for the life of the process. The credential store is readable a moment later, so
//  the Firebase page reports the project as fully set up while every action that needs the
//  service answers "Push notifications are not running on this server".
//
//  Reported exactly that way: push shown as set up, project id on screen, and "Check Security
//  Rules" refusing.
//
//  See `Sources/BlueBubblesApp/FirebaseSetupModel.swift`.

import BBInterfaces
import BBPersistence
import BBPushKit
import BBSettings
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Push self-heal")
@MainActor
struct PushSelfHealTests {

  /// A minimal, valid service-account key. Nothing signs with it; `ServiceAccount.parse`
  /// insists the field is present, which is what makes "credentials exist" answerable.
  private static let serviceAccountJSON = """
    {
      "type": "service_account",
      "project_id": "bluebubbles-a1b2c3d4e5f6a7b8",
      "private_key_id": "abc123",
      "private_key": "-----BEGIN PRIVATE KEY-----\\nnot-a-real-key\\n-----END PRIVATE KEY-----\\n",
      "client_email": "firebase-adminsdk@bluebubbles-a1b2c3d4e5f6a7b8.iam.gserviceaccount.com",
      "client_id": "12345",
      "token_uri": "https://oauth2.googleapis.com/token"
    }
    """

  private actor Reloads {
    private(set) var count = 0
    func record() { count += 1 }
  }

  /// A server whose credentials are readable and whose push service is not running: the
  /// state the gate leaves behind when it could not read the Keychain at startup.
  private struct StalledPush: PushSetupProviding {
    let settings: SettingsStore
    let credentials: PushCredentialStore
    let reloads: Reloads

    func pushInterface() async -> PushInterface {
      PushInterface(
        credentials: credentials,
        settings: settings,
        // Still nil after a reload: a real registry would start the service, and what is
        // under test is that the reload is ASKED FOR. Leaving it nil also proves the
        // recovery is attempted once per action rather than looping.
        service: nil,
        deviceTokens: { [] },
        reloadPush: { await reloads.record() }
      )
    }
  }

  private static func stalledPush(withCredentials: Bool) async throws -> (StalledPush, Reloads) {
    let secrets = InMemorySecretStore()
    let credentials = PushCredentialStore(secrets: secrets)
    if withCredentials {
      _ = try await credentials.importServiceAccount(Data(serviceAccountJSON.utf8))
    }
    let reloads = Reloads()
    return (
      StalledPush(
        settings: try await SettingsStore(
          database: try AppDatabase.inMemory(contributors: [SettingsSchema.self]),
          secrets: secrets
        ),
        credentials: credentials,
        reloads: reloads
      ),
      reloads
    )
  }

  @Test("An action on a credentialled-but-stopped server asks for push to be started")
  func reloadsWhenConfiguredAndStopped() async throws {
    let model = FirebaseSetupModel()
    let (push, reloads) = try await Self.stalledPush(withCredentials: true)

    model.repairRules(push: push)
    await model.settle()

    #expect(await reloads.count == 1)
  }

  /// The service account ALONE is what the startup gate reads
  /// (`PushCredentialStore.isConfigurable`), so it is what decides whether a reload could
  /// help. A server with a key and no `google-services.json` can still send notifications,
  /// and gating this on both files would leave precisely that one unable to recover.
  @Test("A service account with no client config is still worth reloading for")
  func reloadsWithServiceAccountAlone() async throws {
    let model = FirebaseSetupModel()
    let (push, reloads) = try await Self.stalledPush(withCredentials: true)

    model.repairRules(push: push)
    await model.settle()

    #expect(await reloads.count == 1)
  }

  /// With no credentials, "not running" is the correct answer and a reload would only
  /// restart a service that declines again for the same reason.
  @Test("An unconfigured server is left alone")
  func doesNotReloadWhenUnconfigured() async throws {
    let model = FirebaseSetupModel()
    let (push, reloads) = try await Self.stalledPush(withCredentials: false)

    model.repairRules(push: push)
    await model.settle()

    #expect(await reloads.count == 0)
  }

  /// The user still gets told when the recovery did not take, rather than the button
  /// appearing to do nothing.
  @Test("A reload that does not start push still reports the failure")
  func stillReportsWhenReloadDoesNotHelp() async throws {
    let model = FirebaseSetupModel()
    let (push, _) = try await Self.stalledPush(withCredentials: true)

    model.repairRules(push: push)
    await model.settle()

    #expect(model.outcome?.kind == .failure)
  }
}
