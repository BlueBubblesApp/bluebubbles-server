//  ResponseShapeTests
//  A Google response this build cannot read is a failure, not an empty answer.
//
//  The provisioner read a dozen responses with `try?`, so a changed shape from Google reported
//  "no projects", "no keys", "no apps", and a poll it could not read kept polling until the
//  timeout blamed the step for being slow. `GoogleAPIClient.decode` names the call and throws
//  `decodingFailed`; these pin that on the two answers a person sees first.
//
//  NO REAL CREDENTIALS; every value here is invented.

import BBSettings
import Foundation
import Testing

@testable import BBPushKit

@Suite("Unreadable Google responses fail as such")
struct ResponseShapeTests {

  /// Answers every request with one fixed body.
  private struct FixedGoogle: HTTPPerforming {
    let body: String
    func perform(
      method: String, url: String, headers: [String: String], body: Data?
    ) async throws -> (status: UInt, body: Data) {
      (200, Data(self.body.utf8))
    }
  }

  private func provisioner(answering body: String) -> FirebaseProvisioner {
    FirebaseProvisioner(
      api: GoogleAPIClient(http: FixedGoogle(body: body), tokens: StaticTokenProvider(value: "t"))
    )
  }

  @Test("A project listing that is not JSON throws rather than listing nothing")
  func unreadableListingThrows() async {
    await #expect(throws: GoogleAPIError.self) {
      _ = try await provisioner(answering: "<html>Service Unavailable</html>").listProjects()
    }
  }

  @Test("A project listing with no results is still an empty list")
  func emptyListingIsEmpty() async throws {
    let projects = try await provisioner(answering: "{}").listProjects()
    #expect(projects.isEmpty)
  }

  @Test("The failure names the call, so a log line says which answer was unreadable")
  func failureNamesTheCall() async {
    do {
      _ = try await provisioner(answering: "nope").listProjects()
      Issue.record("expected the listing to be refused")
    } catch let error as GoogleAPIError {
      guard case .decodingFailed(let reason) = error else {
        Issue.record("expected decodingFailed, got \(error)")
        return
      }
      #expect(reason.contains("listing Firebase projects"))
    } catch {
      Issue.record("expected a GoogleAPIError, got \(error)")
    }
  }

  /// A secret store whose reads fail, the way a locked Keychain does.
  private struct RefusingSecretStore: SecretStore {
    struct Refused: Error {}
    func get(_ key: String) throws -> String? { throw Refused() }
    func set(_ key: String, value: String) throws { throw Refused() }
    func delete(_ key: String) throws { throw Refused() }
  }

  @Test("A Keychain that will not answer throws from the per-file checks, not \"not stored\"")
  func refusedKeychainThrowsFromMigrationChecks() async {
    let store = PushCredentialStore(secrets: RefusingSecretStore())
    await #expect(throws: RefusingSecretStore.Refused.self) {
      _ = try await store.hasServiceAccount()
    }
    await #expect(throws: RefusingSecretStore.Refused.self) {
      _ = try await store.hasClientConfig()
    }
  }
}
