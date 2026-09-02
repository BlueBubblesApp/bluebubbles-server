//  PushWiringTests
//  Push is reachable, gated correctly, and told when things change.
//
//  Everything asserted here was a call site that did not exist, and every one of them failed
//  silently — which is why these are wiring tests rather than behaviour tests. The behaviour
//  lives in `BBPushKitTests`; what kept being missing was somebody calling it.
//
//    - The startup gate asked the SERVICE whether push was configured, and the gate runs
//      before the service starts, so the answer was always no. Push never started on any
//      install, configured or not.
//    - `new-server` was a defined event name with no emitter and `ServerURLPublisher` had no
//      caller, so a tunnel that came back on a different address told nobody.
//    - `noteClientActivity` was written on both sides and called from neither, so the
//      restart poll stayed at its idle rate and the app's restart button took up to a minute.
//
//  See `docs/EVENTS.md`.

import BBAuth
import BBEvents
import BBPersistence
import BBPushKit
import BBSerialization
import BBServiceKit
import BBSettings
import Foundation
import GRDB
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Push wiring", .serialized)
struct PushWiringTests {

  /// A minimal, valid service-account key. The RSA key is not used by anything here —
  /// nothing signs — but `ServiceAccount.parse` insists on the field being present, which
  /// is the behaviour that makes "credentials exist" a meaningful question.
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

  private static let projectId = "bluebubbles-a1b2c3d4e5f6a7b8"

  /// A realistic `google-services.json`, `client` array included.
  ///
  /// The array is the half of the document this server never reads and no client works
  /// without — `api_key[].current_key` and `client_info.mobilesdk_app_id`. Fixtures that
  /// carried `project_info` alone matched the shape of the storage bug, so nothing built
  /// on them could detect it.
  private static let clientConfigJSON = """
    {
      "project_info": {
        "project_number": "123456789",
        "project_id": "\(projectId)"
      },
      "client": [{
        "client_info": {
          "mobilesdk_app_id": "1:123456789:android:abcdef",
          "android_client_info": { "package_name": "com.bluebubbles.messaging" }
        },
        "api_key": [{ "current_key": "AIzaSyTESTKEY" }],
        "services": {}
      }],
      "configuration_version": "1"
    }
    """

  // MARK: - The gate

  @Test("The startup gate reads the credential store, not the unstarted service")
  func gateReadsCredentials() async throws {
    // THE regression. `PushService.isConfigured` reports what the last `start` found, and
    // `canRun` is consulted BEFORE `start` — so a gate that asked the service was asking
    // a question whose answer is "no" on every server that has not yet started push,
    // which is every server. Push was gated off universally: no failure, no warning, no
    // notification ever sent.
    let secrets = InMemorySecretStore()
    let store = PushCredentialStore(secrets: secrets)
    _ = try await store.importServiceAccount(Data(Self.serviceAccountJSON.utf8))

    let service = PushService(credentials: store)

    // The service has credentials available and still reports itself unconfigured,
    // because nothing has started it. That is precisely the state the gate runs in.
    #expect(await service.isConfigured == false)
    #expect(await store.isConfigurable() == true)
  }

  @Test("With no credentials anywhere, push declines")
  func gateDeclinesWhenUnconfigured() async {
    let store = PushCredentialStore(secrets: InMemorySecretStore())
    // False unless an Electron install left plaintext credentials in Application Support,
    // which a machine running these tests may genuinely have. Asserted as an implication
    // rather than a bare `false` so the suite does not fail on a developer's own Mac.
    if !PushCredentialMigration.hasLegacyCredentials() {
      #expect(await store.isConfigurable() == false)
    }
  }

  @Test("Credentials waiting in Application Support still open the gate")
  func gateAccountsForUnmigratedCredentials() async {
    // The migration out of plaintext runs inside `PushService.start()`. A gate that read
    // the Keychain alone would decline on exactly the installs that have credentials to
    // migrate — and, since the migration is what DELETES the plaintext copies, would
    // leave them readable forever.
    let store = PushCredentialStore(secrets: InMemorySecretStore())
    let configurable = await store.isConfigurable()
    #expect(configurable == PushCredentialMigration.hasLegacyCredentials())
  }

  // MARK: - Address announcement

  @Test("A server_address change reaches the announcer")
  func addressChangeIsAnnounced() async throws {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let store = try await SettingsStore(
      database: database, secrets: InMemorySecretStore()
    )
    let announced = Announcements()

    let propagation = SettingsPropagation(
      settings: store,
      registry: ServiceRegistry(host: EmptyContext()),
      accessControl: AccessControlService(),
      onServerAddressChanged: { address in await announced.record(address) }
    )

    try await store.set(Settings.serverAddress, to: "https://example.ngrok.io")
    await propagation.handle(SettingsChange(changedKeys: ["server_address"]))

    #expect(await announced.values == ["https://example.ngrok.io"])
  }

  @Test("An unrelated change announces nothing")
  func unrelatedChangeIsNotAnnounced() async throws {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let store = try await SettingsStore(
      database: database, secrets: InMemorySecretStore()
    )
    let announced = Announcements()

    let propagation = SettingsPropagation(
      settings: store,
      registry: ServiceRegistry(host: EmptyContext()),
      accessControl: AccessControlService(),
      onServerAddressChanged: { address in await announced.record(address) }
    )
    await propagation.handle(SettingsChange(changedKeys: ["socket_port"]))

    #expect(await announced.values.isEmpty)
  }

  @Test("new-server carries the bare address, not an object")
  func newServerPayloadShape() async {
    // `emitMessage(NEW_SERVER, server_address, "high")` — clients read the payload AS the
    // address. Wrapping it in an object would be tidier and would break all of them.
    let bus = EventBus()
    let sink = RecordingSink()
    await bus.register(sink)

    await bus.emit(
      ServerEvent(
        name: .newServer,
        fullPayload: .string("https://example.ngrok.io"),
        priority: .high
      )
    )
    await bus.settle()

    #expect(await sink.received.first?.name == .newServer)
    #expect(await sink.received.first?.fullPayload.stringValue == "https://example.ngrok.io")
  }

  @Test("new-server reaches push and webhooks as well as the socket")
  func newServerRouting() {
    // A client that is not connected right now is exactly the one that needs to be told
    // the address moved, so suppressing push here would defeat the point.
    let routing = EventRouting.policy(for: .newServer)
    #expect(routing.allowsSocket)
    #expect(routing.allowsPush)
    #expect(routing.allowsWebhooks)
  }

  // MARK: - Credential import

  @Test("Importing a key stores it, deletes the original, and restarts push")
  func importStoresAndReloads() async throws {
    // Three assertions and each one is a separate defect if it goes missing. Deleting the
    // source file is the vulnerability #1 fix: the file a user just picked is almost
    // always in Downloads, readable by anything running as them, and leaving it there puts
    // the credential back beside the Keychain entry that exists to protect it. And the
    // reload is what makes setup finish — without it push stays exactly as it was until
    // the server is restarted, which nothing on the screen tells the user to do.
    let secrets = InMemorySecretStore()
    let reloads = Reloads()
    let interface = try await makeInterface(secrets: secrets, reloads: reloads)

    let file = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-service-account-\(UUID().uuidString).json")
    try Data(Self.serviceAccountJSON.utf8).write(to: file)

    _ = try await interface.importCredentials(from: [file])

    // Read back through the store rather than by Keychain account name, which is
    // internal to BBPushKit — and which is the right boundary: what matters is that the
    // credential is retrievable, not where it was filed.
    #expect(try await PushCredentialStore(secrets: secrets).serviceAccount() != nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(await reloads.count == 1)

    // A service account ALONE is not a configured server, and saying so was the defect:
    // `GET /api/v1/fcm/client` has nothing to serve, so no client can register for a
    // notification, while the screen reported setup as complete.
    let status = await interface.status()
    #expect(status.hasServiceAccount)
    #expect(!status.hasClientConfig)
    #expect(!status.isConfigured)
  }

  @Test("Both files together make a configured server")
  func importingBothHalvesConfigures() async throws {
    let secrets = InMemorySecretStore()
    let interface = try await makeInterface(secrets: secrets, reloads: Reloads())

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    let key = directory.appendingPathComponent("bb-key-\(UUID().uuidString).json")
    let services = directory.appendingPathComponent("bb-svc-\(UUID().uuidString).json")
    try Data(Self.serviceAccountJSON.utf8).write(to: key)
    try Data(Self.clientConfigJSON.utf8).write(to: services)

    // Dropped together and in the "wrong" order — the classifier reads contents, so the
    // order they arrive in must not matter.
    let inspection = try await interface.importCredentials(from: [services, key])
    #expect(inspection.rejected.isEmpty)
    #expect(inspection.projectChange == nil)

    let status = await interface.status()
    #expect(status.isConfigured)

    // The whole document survives. This is the regression that matters most: re-encoding
    // the client configuration from a three-field projection drops the API key every Android
    // client needs, at import, while the response still looks well-formed.
    let stored = try await PushCredentialStore(secrets: secrets).rawClientConfig()
    let text = String(decoding: try #require(stored), as: UTF8.self)
    #expect(text.contains("AIzaSyTESTKEY"))
    #expect(text.contains("mobilesdk_app_id"))
  }

  @Test("A file that is neither credential is reported per file, not as a failed drop")
  func importRejectsUnrelatedJSON() async throws {
    // Both credentials are JSON and both get renamed, so the filename says nothing. A
    // classifier that trusted it would import the wrong one and leave push half-configured
    // while reporting success.
    let interface = try await makeInterface(secrets: InMemorySecretStore(), reloads: Reloads())

    let file = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("server.json")
    try Data(#"{"hello":"world"}"#.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let inspection = try await interface.importCredentials(from: [file])
    #expect(!inspection.hasSomethingToImport)
    #expect(inspection.rejected.count == 1)
    #expect(inspection.rejected.first?.name == "server.json")
    // And the file it could not understand is left alone rather than deleted.
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test("A google-services.json with no registered app is refused, naming the reason")
  func clientConfigWithoutClientArrayIsRefused() async throws {
    // The exact document the old storage path produced. Accepting it stores a file no
    // client can use, and the failure then surfaces on the phone rather than here.
    let interface = try await makeInterface(secrets: InMemorySecretStore(), reloads: Reloads())

    let file = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("google-services-\(UUID().uuidString).json")
    try Data(#"{"project_info":{"project_number":"1","project_id":"P"}}"#.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let inspection = try await interface.importCredentials(from: [file])
    #expect(!inspection.hasSomethingToImport)
    #expect(inspection.rejected.first?.reason.contains("client") == true)
  }

  @Test("Toggling remote restart reads back the value that was just saved")
  func remoteRestartTogglePersists() async throws {
    // The switch showed a success message and then snapped straight back. `status()`
    // preferred the RUNNING service's `remoteRestartEnabled`, and a service reports the
    // value it was started with — so the control read the pre-restart value while the
    // save had in fact succeeded. It is a setting; the settings store is authoritative.
    let secrets = InMemorySecretStore()
    let interface = try await makeInterface(secrets: secrets, reloads: Reloads())

    let file = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-key-\(UUID().uuidString).json")
    try Data(Self.serviceAccountJSON.utf8).write(to: file)
    _ = try await interface.importCredentials(from: [file])

    #expect(await interface.status().remoteRestartEnabled)

    try await interface.setRemoteRestartEnabled(false)
    #expect(await interface.status().remoteRestartEnabled == false)

    try await interface.setRemoteRestartEnabled(true)
    #expect(await interface.status().remoteRestartEnabled)
  }

  @Test("Disconnect reports nothing configured, even before push has restarted")
  func disconnectIsReportedImmediately() async throws {
    // The credential store is authoritative for what EXISTS; a running service only
    // describes what it is doing. Asking the service first meant disconnect cleared both
    // entries and then reported the service account as still present — the service had
    // not restarted yet and was still describing the credentials it started with. The
    // screen said "half set up, google-services.json missing" and a second Disconnect
    // looked necessary. Nothing had failed to delete.
    let secrets = InMemorySecretStore()
    let interface = try await makeInterface(secrets: secrets, reloads: Reloads())

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    let key = directory.appendingPathComponent("bb-key-\(UUID().uuidString).json")
    let services = directory.appendingPathComponent("bb-svc-\(UUID().uuidString).json")
    try Data(Self.serviceAccountJSON.utf8).write(to: key)
    try Data(Self.clientConfigJSON.utf8).write(to: services)
    _ = try await interface.importCredentials(from: [key, services])
    #expect(await interface.status().isConfigured)

    try await interface.disconnect()

    // BOTH halves gone, in one call, with no second Disconnect required.
    let status = await interface.status()
    #expect(!status.hasServiceAccount)
    #expect(!status.hasClientConfig)
    #expect(status.projectId == nil)
    #expect(try await PushCredentialStore(secrets: secrets).rawClientConfig() == nil)
    #expect(try await PushCredentialStore(secrets: secrets).rawServiceAccount() == nil)
  }

  @Test("Credentials for a different project raise the device-clearing question first")
  func projectChangeIsDetectedBeforeAnythingIsWritten() async throws {
    // The reference server asks this and clears devices on a yes. Nothing asked it here,
    // so swapping projects kept a device list holding tokens minted by the OLD project —
    // every send failing with the one error the sender deliberately does not report.
    let secrets = InMemorySecretStore()
    let interface = try await makeInterface(secrets: secrets, reloads: Reloads())

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    let first = directory.appendingPathComponent("bb-a-\(UUID().uuidString).json")
    try Data(Self.serviceAccountJSON.utf8).write(to: first)
    _ = try await interface.importCredentials(from: [first])

    let second = directory.appendingPathComponent("bb-b-\(UUID().uuidString).json")
    let other = Self.serviceAccountJSON
      .replacingOccurrences(of: Self.projectId, with: "bluebubbles-other-project")
    try Data(other.utf8).write(to: second)
    defer { try? FileManager.default.removeItem(at: second) }

    let inspection = await interface.inspect([second])
    #expect(inspection.projectChange?.from == Self.projectId)
    #expect(inspection.projectChange?.to == "bluebubbles-other-project")
    // Inspection alone must not have written anything — the question comes first.
    #expect(FileManager.default.fileExists(atPath: second.path))
    #expect(await PushCredentialStore(secrets: secrets).currentProjectId() == Self.projectId)
  }

  private func makeInterface(
    secrets: any SecretStore,
    reloads: Reloads
  ) async throws -> PushInterface {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    return PushInterface(
      credentials: PushCredentialStore(secrets: secrets),
      settings: try await SettingsStore(database: database, secrets: secrets),
      service: nil,
      deviceTokens: { [] },
      reloadPush: { await reloads.record() }
    )
  }

  private actor Reloads {
    private(set) var count = 0
    func record() { count += 1 }
  }

  // MARK: - Restart responsiveness

  @Test("An authenticated request reports client activity")
  func authenticatedRequestReportsActivity() async throws {
    // The plan rules out a slow restart button as a user-visible regression, and the
    // watcher's fast/slow split is what avoids it — but only if something tells it a
    // client is there. Nothing did: `noteClientActivity` existed on the watcher, on the
    // service and on the context, and no request path called any of them. The proxy's
    // idle check read the same dead timestamp.
    let seen = Activity()
    try await withServer(
      onClientActivity: { await seen.record() },
      body: { port in
        _ = try? await Self.get(port: port, path: "/api/v1/test/guarded")
      })
    #expect(await seen.count == 1)
  }

  @Test("An unauthenticated request reports nothing")
  func unauthenticatedRequestIsNotActivity() async throws {
    // A port scanner is not a client. Counting one would hold the fast poll — and the
    // tunnel's idle timer — open against a server nobody is actually using.
    let seen = Activity()
    try await withServer(
      onClientActivity: { await seen.record() },
      body: { port in
        _ = try? await Self.get(port: port, path: "/api/v1/test/open")
      })
    #expect(await seen.count == 0)
  }

  // MARK: - HTTP harness

  private static let probeGroup = RouteGroup(
    "PushProbe", prefix: "test",
    routes: [
      .init(.get, "guarded", HandlerID("test.guarded")),
      .init(.get, "open", HandlerID("test.open"), requires: .unauthenticated),
    ])

  /// Runs a real listener, because the thing under test is where the dispatch path calls
  /// the hook — a hand-rolled harness would exercise the call site this test exists to pin.
  private func withServer(
    onClientActivity: @escaping @Sendable () async -> Void,
    body: (Int) async throws -> Void
  ) async throws {
    // Port 0 rather than a guess. The retry loop this replaced was written against exactly
    // the right diagnosis — "a test that fails one run in a few hundred is worse than no
    // test, nobody trusts it and everybody re-runs it" — but retrying a guess only lowers
    // the odds. Asking the kernel removes them. See `EphemeralPort`.
    let listener = HTTPListener()
    var registry = HandlerRegistry()
    registry.register(HandlerID("test.guarded")) { _ in .data(.string("ok")) }
    registry.register(HandlerID("test.open")) { _ in .data(.string("ok")) }
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)

    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(),
      authentication: AuthenticationStage(
        chain: AuthenticationChain(schemes: [AlwaysAuthenticates()]),
        accessControl: AccessControlService()
      ),
      privateAPI: PrivateAPIStage(isConnected: { true }),
      onClientActivity: onClientActivity
    )
    try await listener.start(
      router: try builder.buildRouter(
        registry: registry, additionalGroups: [Self.probeGroup]
      ),
      host: "127.0.0.1",
      port: 0
    )
    let port = try await listener.boundPortOrFail()

    // Awaited, not deferred into a detached task. `defer` cannot await, so the spawned
    // stop may not have run before the next test binds — which is a port collision
    // reported as a bind failure in an unrelated test.
    do {
      try await body(port)
    } catch {
      await listener.stop()
      throw error
    }
    await listener.stop()
  }

  private static func get(port: Int, path: String) async throws -> Data {
    let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    let (data, _) = try await URLSession.shared.data(for: request)
    return data
  }

  private struct AlwaysAuthenticates: AuthenticationScheme {
    let id = "test-always"
    func authenticate(
      _ presentation: CredentialPresentation
    ) async throws -> AuthenticatedPrincipal? {
      AuthenticatedPrincipal(deviceID: nil, scopes: Scope.all, schemeID: id)
    }
  }

  private actor Activity {
    private(set) var count = 0
    func record() { count += 1 }
  }

  // MARK: - Doubles

  private actor Announcements {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
  }

  private actor RecordingSink: EventSink {
    nonisolated let id = SinkID.webhook
    nonisolated let projection = PayloadProjection.full
    nonisolated let routing = SinkRouting.webhook
    private(set) var received: [ServerEvent] = []
    func accepts(_ event: ServerEvent) async -> Bool { true }
    func deliver(_ event: ServerEvent) async throws { received.append(event) }
  }

  private struct EmptyContext: Sendable {}

}

//  MARK: - Legacy configuration import
//
//  `LegacyConfigMigration` has to be CALLED, not merely correct. Unwired, an upgrading
//  Electron user's port, password, proxy provider, ngrok key and tunnel settings are all
//  silently discarded: the server comes up on defaults, on a different port, with no
//  password, and nothing explains why. Its unit tests pass either way, which is exactly why
//  these are wiring tests.

@Suite("Legacy configuration import")
struct LegacyConfigWiringTests {

  private func makeLegacyDatabase(_ values: [String: String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-legacy-\(UUID().uuidString).db")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE config (name TEXT PRIMARY KEY, value TEXT)")
      for (name, value) in values {
        try db.execute(
          sql: "INSERT INTO config (name, value) VALUES (?, ?)",
          arguments: [name, value]
        )
      }
    }
    return url
  }

  @Test("The import runs once and does not re-run over changed settings")
  func importIsMarkedAndNotRepeated() async throws {
    // The bug the marker prevents. `LegacyConfigMigration.run` writes every key it finds
    // without comparing against the current value, so an unguarded call at startup would
    // re-import on EVERY launch — quietly reverting whatever the user had changed in the
    // Swift app back to whatever the old server happened to hold.
    let secrets = InMemorySecretStore()
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let store = try await SettingsStore(database: database, secrets: secrets)
    let url = try makeLegacyDatabase(["socket_port": "45001"])
    defer { try? FileManager.default.removeItem(at: url) }

    _ = try await LegacyConfigMigration().run(from: url, into: store, secrets: secrets)
    try await store.set(Settings.legacyConfigImported, to: true)
    #expect(await store.get(Settings.socketPort) == 45001)

    // The user then changes it in the Swift app.
    try await store.set(Settings.socketPort, to: 1234)

    // A second startup must leave that alone.
    if await !store.get(Settings.legacyConfigImported) {
      _ = try await LegacyConfigMigration().run(from: url, into: store, secrets: secrets)
    }
    #expect(
      await store.get(Settings.socketPort) == 1234,
      "the import re-ran and reverted a setting the user had changed"
    )
  }

  @Test("The marker setting is registered")
  func markerIsRegistered() {
    // A setting missing from `allKeys` does not migrate and does not render, and both
    // failures are silent — `SettingsRegistryTests` checks uniqueness, not membership.
    #expect(Settings.allKeys.contains("legacy_config_imported"))
  }
}

// MARK: - Serving the client configuration

/// What `GET /api/v1/fcm/client` hands back.
///
/// This response is the whole reason the client configuration is stored as bytes. A client
/// builds its `FirebaseOptions` from `client[].api_key[].current_key` and
/// `client_info.mobilesdk_app_id`; the server itself reads neither, so a response assembled
/// from a model of what the SERVER needs is a well-formed document that no client can use.
@Suite("FCM client configuration response")
struct ClientConfigResponseTests {

  private static let full = """
    {
      "project_info": { "project_number": "123456789", "project_id": "P" },
      "client": [{
        "client_info": {
          "mobilesdk_app_id": "1:123456789:android:abcdef",
          "android_client_info": { "package_name": "com.bluebubbles.messaging" }
        },
        "api_key": [{ "current_key": "AIzaSyTESTKEY" }]
      }],
      "configuration_version": "1"
    }
    """

  @Test("The whole document is served, API key and app ID included")
  func servesTheWholeDocument() throws {
    let patched = PushHandlers.patchOAuthClient(in: try JSONValue.parse(Data(Self.full.utf8)))

    let client = try #require(patched["client"]?[0])
    #expect(client["api_key"]?[0]?["current_key"]?.stringValue == "AIzaSyTESTKEY")
    #expect(client["client_info"]?["mobilesdk_app_id"]?.stringValue == "1:123456789:android:abcdef")
    #expect(patched["configuration_version"]?.stringValue == "1")
    #expect(patched["project_info"]?["project_number"]?.stringValue == "123456789")
  }

  @Test("The oauth_client Google stopped emitting is restored with the project number")
  func restoresOAuthClient() throws {
    // Google dropped this array in May 2023 and Android clients fail on its absence
    // rather than on an empty one. The reference server synthesizes it from the project
    // number, and this must match — an empty array is not the compatible answer.
    let patched = PushHandlers.patchOAuthClient(in: try JSONValue.parse(Data(Self.full.utf8)))

    let oauth = try #require(patched["client"]?[0]?["oauth_client"]?[0])
    #expect(oauth["client_id"]?.stringValue == "123456789")
    #expect(oauth["client_type"]?.intValue == 3)
  }

  @Test("The project number is recovered from the app ID when project_info lacks it")
  func recoversClientIdFromAppId() throws {
    let noNumber = """
      {"project_info":{"project_id":"P"},
       "client":[{"client_info":{"mobilesdk_app_id":"1:999888:android:zz"},
       "api_key":[{"current_key":"k"}]}]}
      """
    let patched = PushHandlers.patchOAuthClient(in: try JSONValue.parse(Data(noNumber.utf8)))
    #expect(patched["client"]?[0]?["oauth_client"]?[0]?["client_id"]?.stringValue == "999888")
  }

  @Test("An oauth_client Google did supply is left exactly as it is")
  func doesNotOverwriteAnExistingOAuthClient() throws {
    let withOAuth = """
      {"project_info":{"project_number":"1"},
       "client":[{"oauth_client":[{"client_id":"real-one","client_type":3}],
       "api_key":[{"current_key":"k"}]}]}
      """
    let patched = PushHandlers.patchOAuthClient(in: try JSONValue.parse(Data(withOAuth.utf8)))
    #expect(patched["client"]?[0]?["oauth_client"]?[0]?["client_id"]?.stringValue == "real-one")
  }
}

/// The rules check reports the rules it actually verified.
///
/// A fixed sentence claiming "the restart channel is scoped", printed whichever way the
/// switch is set, states the opposite of the truth immediately after the channel is closed. A
/// report that cannot be wrong about this has to carry the setting the check ran under.
@Suite("Security rules check reporting", .serialized)
struct RulesCheckReportingTests {

  @Test("The result carries the restart setting the check ran under")
  func resultCarriesTheSetting() {
    // Pinned as a value type rather than through the network path: what matters is that
    // the flag travels WITH the outcome, so no caller has to guess or re-read it.
    let on = RulesCheckResult(republished: false, remoteRestartEnabled: true)
    let off = RulesCheckResult(republished: true, remoteRestartEnabled: false)

    #expect(on.remoteRestartEnabled)
    #expect(!on.republished)
    #expect(!off.remoteRestartEnabled)
    #expect(off.republished)
    // The two are distinguishable, which is the whole point — one sentence could not
    // describe both.
    #expect(on != RulesCheckResult(republished: false, remoteRestartEnabled: false))
  }
}
