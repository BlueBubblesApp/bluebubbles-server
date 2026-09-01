//  CredentialsAndSendTests
//  Where credentials live, and what actually goes over the wire to FCM.
//
//  NO REAL CREDENTIALS — every key here is generated per-run and discarded.

import BBSettings
import Foundation
import Testing

@testable import BBPushKit

private let sampleServiceAccount = """
  {
    "type": "service_account",
    "project_id": "bluebubbles-test",
    "private_key_id": "abc123",
    "private_key": "-----BEGIN PRIVATE KEY-----\\nnot-a-real-key\\n-----END PRIVATE KEY-----\\n",
    "client_email": "test@bluebubbles-test.iam.gserviceaccount.com",
    "token_uri": "https://oauth2.googleapis.com/token"
  }
  """

@Suite("Service account parsing")
struct ServiceAccountParsingTests {

  @Test("A well-formed key file parses")
  func parsesValidAccount() throws {
    let account = try ServiceAccount.parse(Data(sampleServiceAccount.utf8))
    #expect(account.projectId == "bluebubbles-test")
    #expect(account.clientEmail == "test@bluebubbles-test.iam.gserviceaccount.com")
    #expect(account.tokenURI == "https://oauth2.googleapis.com/token")
  }

  /// The console will happily hand out an OAuth *client* JSON, which looks similar and
  /// fails much later with an authentication error that says nothing about the cause.
  @Test("A non-service-account file is rejected at import, not at first send")
  func rejectsWrongFileType() {
    let oauthClient = """
      {"type": "authorized_user", "project_id": "p",
       "private_key": "-----BEGIN PRIVATE KEY-----\\nx\\n-----END PRIVATE KEY-----",
       "client_email": "e"}
      """
    #expect(throws: PushConfigurationError.notAServiceAccount(found: "authorized_user")) {
      _ = try ServiceAccount.parse(Data(oauthClient.utf8))
    }
  }

  @Test("A file without a PEM key is rejected")
  func rejectsMissingKey() {
    let noKey = """
      {"type": "service_account", "project_id": "p",
       "private_key": "oops", "client_email": "e"}
      """
    #expect(throws: PushConfigurationError.self) {
      _ = try ServiceAccount.parse(Data(noKey.utf8))
    }
  }

  @Test("Malformed JSON is reported as malformed")
  func rejectsGarbage() {
    #expect(throws: PushConfigurationError.self) {
      _ = try ServiceAccount.parse(Data("not json".utf8))
    }
  }

  /// The client config's nesting is Google's, and the database kind is derived from whether
  /// a Realtime URL is present — which is how the current server decides too.
  @Test("The client config reports which database the project uses")
  func clientConfigDatabaseKind() throws {
    let firestore = """
      {"project_info": {"project_number": "123", "project_id": "p"}}
      """
    let realtime = """
      {"project_info": {"project_number": "123", "project_id": "p",
       "firebase_url": "https://p.firebaseio.com"}}
      """
    let decoder = JSONDecoder()
    #expect(
      try decoder.decode(FirebaseClientConfig.self, from: Data(firestore.utf8))
        .databaseKind == .firestore)
    #expect(
      try decoder.decode(FirebaseClientConfig.self, from: Data(realtime.utf8))
        .databaseKind == .realtime)
  }
}

@Suite("Credential storage")
struct CredentialStorageTests {

  /// Vulnerability #1: today these sit unencrypted in Application Support, where any
  /// program running as the user can read them — and with them, redirect every client.
  @Test("An imported credential goes to the secret store, not to a file")
  func importGoesToSecretStore() async throws {
    let secrets = InMemorySecretStore()
    let store = PushCredentialStore(secrets: secrets)

    let account = try await store.importServiceAccount(Data(sampleServiceAccount.utf8))
    #expect(account.projectId == "bluebubbles-test")

    // Present in the store...
    #expect(try await store.serviceAccount()?.projectId == "bluebubbles-test")
    // ...and under the expected key, so migration and clearing can find it.
    #expect(try secrets.get(PushCredentialStore.serviceAccountKey) != nil)
  }

  /// Importing must delete the file the user pointed at. Leaving it in Downloads recreates
  /// exactly the exposure this is meant to close, and now there are two copies.
  @Test("Importing deletes the plaintext file it read")
  func importDeletesSourceFile() async throws {
    let path = NSTemporaryDirectory() + "bb-cred-\(UUID().uuidString.prefix(8)).json"
    try Data(sampleServiceAccount.utf8).write(to: URL(fileURLWithPath: path))
    #expect(FileManager.default.fileExists(atPath: path))

    let store = PushCredentialStore(secrets: InMemorySecretStore())
    _ = try await store.importServiceAccount(
      Data(sampleServiceAccount.utf8), deletingFileAt: path
    )
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  /// A rejected file must not delete the user's download — they will need it to retry.
  @Test("A rejected import leaves the file alone")
  func rejectedImportKeepsFile() async throws {
    let path = NSTemporaryDirectory() + "bb-bad-\(UUID().uuidString.prefix(8)).json"
    try Data("not json".utf8).write(to: URL(fileURLWithPath: path))

    let store = PushCredentialStore(secrets: InMemorySecretStore())
    _ = try? await store.importServiceAccount(Data("not json".utf8), deletingFileAt: path)
    #expect(FileManager.default.fileExists(atPath: path))
    try? FileManager.default.removeItem(atPath: path)
  }

  /// Push is optional. With nothing configured the server must start clean, not complain.
  @Test("An empty store reports unconfigured rather than failing")
  func unconfiguredIsNormal() async throws {
    let store = PushCredentialStore(secrets: InMemorySecretStore())
    #expect(await !store.isConfigured())
    #expect(try await store.serviceAccount() == nil)
  }

  @Test("Clearing removes both credentials")
  func clearRemovesEverything() async throws {
    let store = PushCredentialStore(secrets: InMemorySecretStore())
    _ = try await store.importServiceAccount(Data(sampleServiceAccount.utf8))
    #expect(await store.isConfigured())

    try await store.clear()
    #expect(await !store.isConfigured())
  }
}

// MARK: - FCM request shape

/// Captures what would have gone to Google.
private final class RecordingHTTP: HTTPPerforming, @unchecked Sendable {
  struct Call: Sendable {
    let method: String
    let url: String
    let body: Data?
  }

  private let lock = NSLock()
  private var _calls: [Call] = []
  var calls: [Call] { lock.withLock { _calls } }

  var response: (status: UInt, body: Data) = (200, Data("{}".utf8))

  func perform(method: String, url: String, headers: [String: String], body: Data?)
    async throws -> (status: UInt, body: Data)
  {
    lock.withLock { _calls.append(Call(method: method, url: url, body: body)) }
    return response
  }
}

private struct StubExchanger: TokenExchanging {
  func exchange(assertion: String, tokenURI: String) async throws -> AccessToken {
    AccessToken(value: "test-token", expiresAt: Date().addingTimeInterval(3600))
  }
}

private func makeSender(http: RecordingHTTP) throws -> FCMSender {
  // A REAL generated key, not a placeholder. The token provider signs an assertion before
  // any request goes out, so a bogus key fails there and the HTTP layer is never reached —
  // which makes every assertion about the request silently vacuous.
  let key = try TestKey.makePEM()
  let tokens = GoogleTokenProvider(
    account: ServiceAccount(
      projectId: "bluebubbles-test", privateKeyId: "k",
      privateKey: key.pem, clientEmail: "e"
    ),
    exchanger: StubExchanger()
  )
  return FCMSender(
    api: GoogleAPIClient(http: http, tokens: tokens),
    projectId: "bluebubbles-test"
  )
}

@Suite("FCM request shape")
struct FCMRequestTests {

  /// HTTP v1 has no multicast, so three devices means three requests — which is what makes
  /// per-token pruning possible.
  @Test("Each device gets its own request to the v1 endpoint")
  func onePostPerDevice() async throws {
    let http = RecordingHTTP()
    let sender = try makeSender(http: http)

    _ = try await sender.send(
      data: ["type": "new-message"], to: ["device-a", "device-b", "device-c"]
    )

    #expect(http.calls.count == 3)
    for call in http.calls {
      #expect(call.method == "POST")
      #expect(call.url == "https://fcm.googleapis.com/v1/projects/bluebubbles-test/messages:send")
    }
  }

  /// The legacy library took a TTL in milliseconds — the current server passes
  /// `24 * 60 * 60 * 1000` with a comment noting the docs disagree. HTTP v1 wants a duration
  /// STRING in seconds, and `86400000s` would be a TTL of nearly three years.
  @Test("The message is data-only with a 24-hour TTL in v1's format")
  func messageShape() async throws {
    let http = RecordingHTTP()
    let sender = try makeSender(http: http)

    _ = try await sender.send(
      data: ["type": "new-message", "guid": "A1"], to: ["device-a"], priority: .high
    )

    let body = try #require(http.calls.first?.body)
    let object = try #require(
      try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    let message = try #require(object["message"] as? [String: Any])

    #expect(message["token"] as? String == "device-a")
    #expect((message["data"] as? [String: String])?["guid"] == "A1")
    // Data-only: a `notification` block would make the OS render its own alert.
    #expect(message["notification"] == nil)

    let android = try #require(message["android"] as? [String: Any])
    #expect(android["priority"] as? String == "high")
    #expect(android["ttl"] as? String == "86400s")
  }

  /// Checked once, not per device: the payload is identical for all of them, so failing
  /// thirty requests to learn the same fact is waste.
  @Test("An oversized payload fails without contacting FCM at all")
  func oversizedPayloadShortCircuits() async throws {
    let http = RecordingHTTP()
    let sender = try makeSender(http: http)

    let huge = String(repeating: "x", count: FCMSender.maximumPayloadBytes + 100)
    let report = try await sender.send(data: ["blob": huge], to: ["device-a", "device-b"])

    #expect(http.calls.isEmpty)
    #expect(report.outcomes["device-a"] == .payloadTooLarge)
    #expect(report.outcomes["device-b"] == .payloadTooLarge)
  }

  @Test("Sending to nobody does nothing")
  func emptyTokenListDoesNothing() async throws {
    let http = RecordingHTTP()
    let report = try await makeSender(http: http).send(data: ["a": "b"], to: [])
    #expect(http.calls.isEmpty)
    #expect(report.outcomes.isEmpty)
  }

  /// The whole reason per-token delivery is an improvement: FCM names the dead device, so
  /// it is pruned now rather than in a month.
  @Test("A dead token is reported for immediate pruning")
  func deadTokenIsReported() async throws {
    let http = RecordingHTTP()
    http.response = (404, Data(#"{"error":{"status":"UNREGISTERED","message":"gone"}}"#.utf8))

    let report = try await makeSender(http: http).send(data: ["a": "b"], to: ["dead-device"])
    #expect(report.expiredTokens == ["dead-device"])
  }
}
