//  AppContextFixture
//  A real `AppContext`, cheap enough for a test to build.
//
//  There was no way to construct one, and that is why two wiring bugs shipped invisibly: the
//  contacts ingestor and the update installer were both late-binding points that NOTHING ever
//  called, so `contact/refresh` refused on servers with Contacts granted and the update
//  endpoint claimed the server was headless when it was not. Neither is visible to the
//  compiler, and neither was reachable by a test, so neither was caught.
//
//  Everything here is in-memory or defaulted. No chat.db — `messages`, `serializer` and
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
import BBSettings
import BBSocketIO
import BBSystem
import BBTooling
import Foundation
import Logging

@testable import BlueBubblesServerCore

enum AppContextFixture {

  /// An unwired context: built, but `finishWiring` has not run.
  static func make() async throws -> AppContext {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let secrets = InMemorySecretStore()
    let settings = try await SettingsStore(database: database, secrets: secrets)

    let socketServer = SocketServer()
    let tokenAuth = TokenAuthService()
    let passwordDigests = PasswordDigestCache(load: { nil })

    return AppContext(
      appDatabase: database,
      chatDatabase: nil,
      settings: settings,
      secrets: secrets,
      schemaProfile: nil,
      messages: nil,
      contacts: ContactIndex(database: database),
      serializer: nil,
      events: EventBus(),
      codecs: .legacyOnly(),
      socketServer: socketServer,
      engineIO: EngineIOServer(
        server: socketServer,
        chain: { await tokenAuth.chain(passwordProvider: { await passwordDigests.digest() }) }
      ),
      additionalRouteGroups: [],
      permissions: PermissionsService(),
      accessControl: AccessControlService(),
      tokenAuth: tokenAuth,
      passwordDigests: passwordDigests,
      tools: ToolManager(),
      alerts: AlertCenter(),
      logger: Logger(label: "bluebubbles.test")
    )
  }
}
