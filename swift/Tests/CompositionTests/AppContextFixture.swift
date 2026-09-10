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

import BBAuth
import BBContacts
import BBDiagnostics
import BBEvents
import BBHTTPAPI
import BBPersistence
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
  static func make(withMessageAccess: Bool = false) async throws -> AppContext {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let secrets = InMemorySecretStore()
    let settings = try await SettingsStore(database: database, secrets: secrets)

    let socketServer = SocketServer()
    let tokenAuth = TokenAuthService()
    let passwordDigests = PasswordDigestCache(load: { nil })

    let logger = Logger(label: "bluebubbles.test")
    return AppContext(
      storage: ServerComposition.Storage(
        logSink: logSink, logger: logger, appDatabase: database, secrets: secrets,
        settings: settings
      ),
      readPath: ServerComposition.ReadPath(
        database: nil,
        profile: withMessageAccess ? InterfaceFixtures.emptyProfile : nil,
        messages: withMessageAccess ? try InterfaceFixtures.repository() : nil,
        serializer: withMessageAccess
          ? MessageSerializer(profile: InterfaceFixtures.emptyProfile)
          : nil
      ),
      shared: ServerComposition.SharedServices(
        alerts: AlertCenter(),
        permissions: PermissionsService(),
        accessControl: AccessControlService(),
        contacts: ContactIndex(database: database)
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
      tools: ToolManager()
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
