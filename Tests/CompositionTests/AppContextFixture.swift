//  AppContextFixture
//  A real `AppContext`, cheap enough for a test to build.
//
//  There was no way to construct one, and that is why two wiring bugs shipped invisibly: the
//  contacts ingestor and the update installer were both late-binding points that NOTHING ever
//  called, so `contact/refresh` refused on servers with Contacts granted and the update
//  endpoint claimed the server was headless when it was not. Neither is visible to the
//  compiler, and neither was reachable by a test, so neither was caught.
//
//  Everything here is in-memory or defaulted. No chat.db: `messages`, `serializer` and
//  `schemaProfile` are nil, which is a supported configuration (no Full Disk Access) and the
//  one that needs no fixture data.
//
//  See `Sources/BlueBubblesServerCore/Composition/AppContext.swift`.

import BBAudit
import BBAuth
import BBContacts
import BBDiagnostics
import BBEvents
import BBHTTPAPI
import BBIMessage
import BBLicensing
import BBPersistence
import BBProxy
import BBSerialization
import BBSettings
import BBSocketIO
import BBSystem
import BBTestSupport
import BBTooling
import Foundation
import Logging

@testable import BlueBubblesServerCore

enum AppContextFixture {

  /// An unwired context: built, but `finishWiring` has not run.
  /// - Parameter withMessageAccess: supplies an EMPTY message repository and serializer, so
  ///   `interfaces()` returns something instead of nil. The default stays nil because that is
  ///   the no-Full-Disk-Access configuration and the one most of these suites want; pass true
  ///   for a test about the interfaces themselves rather than about the container.
  /// - Parameter chatDatabase: a real `chat.db` to read, for a test that needs rows rather
  ///   than merely a non-nil repository. `withMessageAccess` gives the empty one, which is
  ///   right for a test that only needs the capability to be present.
  static func make(
    withMessageAccess: Bool = false, chatDatabase: ReadOnlyDatabase? = nil
  ) async throws -> AppContext {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let secrets = InMemorySecretStore()
    let settings = try await TestSettings.store(database: database, secrets: secrets)

    let socketServer = SocketServer()
    let tokenAuth = TokenAuthService()
    let passwordDigests = PasswordDigestCache(load: { nil })

    let logger = Logger(label: "bluebubbles.test")

    // Three read paths, and only the middle one needs explaining. A real database is for a
    // test that walks ROWS — the indexer's cursor, a query plan — where the empty repository
    // would assert that a loop terminates and nothing else. `withMessageAccess` remains the
    // right choice for a test that only needs the capability to be non-nil.
    let readPath: ServerComposition.ReadPath
    if let chatDatabase {
      // 14: Sonoma, the deployment floor and the schema the committed fixtures came from.
      let profile = try await SchemaProfile.detect(in: chatDatabase, osMajorVersion: 14)
      readPath = ServerComposition.ReadPath(
        database: chatDatabase, profile: profile,
        messages: MessageRepository(database: chatDatabase, profile: profile),
        serializer: MessageSerializer(profile: profile),
        searchIndex: SearchIndexStore()
      )
    } else {
      readPath = ServerComposition.ReadPath(
        database: nil,
        profile: withMessageAccess ? InterfaceFixtures.emptyProfile : nil,
        messages: withMessageAccess ? try InterfaceFixtures.repository() : nil,
        serializer: withMessageAccess
          ? MessageSerializer(profile: InterfaceFixtures.emptyProfile)
          : nil,
        searchIndex: SearchIndexStore()
      )
    }

    return AppContext(
      storage: ServerComposition.Storage(
        logSink: logSink, logger: logger, appDatabase: database, secrets: secrets,
        settings: settings
      ),
      readPath: readPath,
      shared: ServerComposition.SharedServices(
        alerts: AlertCenter(),
        permissions: PermissionsService(),
        accessControl: AccessControlService(),
        contacts: ContactIndex(database: database),
        auditLog: AuditRecorder(),
        // Unlicensed and pointed at nothing reachable, which is what a shipped build looks
        // like today: no key, so every status is `.none`, and the gate is `.unenforced`
        // while `LicensePublicKey` is empty regardless.
        license: LicenseRuntime(
          store: LicenseStore(settings: settings),
          client: EntitlementClient(endpoint: "https://example.invalid", serverVersion: "test"),
          machine: "test-machine"
        ),
        // A throwaway, never the installation's: see `SharedServices.daemonLedger`.
        daemonLedger: DaemonLedger(
          file: FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-daemons-\(UUID().uuidString).json"))
      ),
      transport: ServerComposition.Transport(
        authMode: .password,
        codecs: .legacyOnly(),
        tokenAuth: tokenAuth,
        passwordDigests: passwordDigests,
        events: EventBus(),
        socketServer: socketServer,
        engineIO: EngineIOServer(
          server: socketServer,
          chain: { await tokenAuth.chain(passwordProvider: { await passwordDigests.digest() }) }
        )
      ),
      additionalRouteGroups: [],
      // A temporary root and an empty prefix list, deliberately. The default `ToolManager`
      // reads and WRITES the real `~/Library/Application Support/bluebubbles-server/Tools`
      // and, now that a scan can spawn processes, would probe whatever this developer's Mac
      // happens to have installed. A test that depends on the machine it runs on is a test
      // that fails for one person.
      tools: ToolManager(
        store: ToolStore(
          root: FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-fixture-tools-\(UUID().uuidString)", isDirectory: true)
        ),
        discovery: ToolDiscovery(prefixes: [])
      )
    )
  }

  /// One log file for the whole test process, in the temporary directory.
  ///
  /// The storage group carries the sink because `GET /server/logs` tails it, and a sink
  /// opens its file when built, so one per fixture would leave a file behind for every
  /// test that asked for a context.
  private static let logSink = FileSink(
    url: FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-tests-\(ProcessInfo.processInfo.processIdentifier).log")
  )
}
