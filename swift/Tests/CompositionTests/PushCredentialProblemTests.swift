//  PushCredentialProblemTests
//  A credential that cannot be READ is reported as that, not as "nothing imported".
//
//  `PushInterface.status()` read both credentials with `try?`, so a Keychain that refused (
//  locked, or an entitlement lost to a rebuild) produced the same `PushStatus` as a fresh
//  install, and the Firebase page offered setup as the remedy. The status now carries the
//  failure separately from the two `has…` flags, and this pins the split.

import BBInterfaces
import BBPersistence
import BBSettings
import Foundation
import Testing

@testable import BBPushKit
@testable import BlueBubblesServerCore

@Suite("Push status tells a refused credential from an absent one")
struct PushCredentialProblemTests {

  /// A secret store whose reads fail, the way a locked Keychain does.
  private struct RefusingSecretStore: SecretStore {
    struct Refused: Error {}
    func get(_ key: String) throws -> String? { throw Refused() }
    func set(_ key: String, value: String) throws { throw Refused() }
    func delete(_ key: String) throws { throw Refused() }
  }

  private func makeInterface(credentials: any SecretStore) async throws -> PushInterface {
    // The settings store gets a working secret store on purpose: the refusal under test is
    // the credential read, not a settings failure masquerading as one.
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    return PushInterface(
      credentials: PushCredentialStore(secrets: credentials),
      settings: try await SettingsStore(database: database, secrets: InMemorySecretStore()),
      service: nil,
      deviceTokens: { [] },
      reloadPush: {}
    )
  }

  @Test("An empty store is not set up, and reports no problem")
  func absentIsNotAProblem() async throws {
    let status = try await makeInterface(credentials: InMemorySecretStore()).status()
    #expect(!status.hasServiceAccount)
    #expect(!status.hasClientConfig)
    #expect(status.credentialProblem == nil)
  }

  @Test("A store that refuses to answer reports the refusal")
  func refusedIsReported() async throws {
    let status = try await makeInterface(credentials: RefusingSecretStore()).status()
    #expect(!status.hasServiceAccount)
    #expect(!status.hasClientConfig)
    #expect(status.credentialProblem != nil)
  }

  @Test("A stored key that no longer parses reports the damage")
  func damagedKeyIsReported() async throws {
    let secrets = InMemorySecretStore()
    try secrets.set(PushCredentialStore.serviceAccountKey, value: "{ not a service account")
    let status = try await makeInterface(credentials: secrets).status()
    #expect(!status.hasServiceAccount)
    #expect(status.credentialProblem != nil)
  }
}
