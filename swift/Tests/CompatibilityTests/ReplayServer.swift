//  ReplayServer
//  The real server, in this process, over a synthetic `chat.db`.
//
//  Every other harness in the suite mounts a throwaway route table with one handler in it,
//  which is right for what those suites test — routing, the envelope, path parameters. This
//  one mounts the SHIPPING registry: `ServerComposition.buildHandlers`, the same call the
//  running server makes, so what the replay diffs is what a client would receive.
//
//  The database is `Tests/BBIMessageTests/ChatDBFixtures/chat-sonoma.db`, reached by path.
//  An empty database would answer every read with an empty array, and an empty array is
//  exactly the case a shape diff cannot see into — the corpus's whole value is the entity
//  fields inside `data`, and three chats with seven messages between them is what makes
//  those fields exist to compare.

import BBAuth
import BBContacts
import BBDiagnostics
import BBEvents
import BBHTTPAPI
import BBIMessage
import BBPersistence
import BBSerialization
import BBServiceKit
import BBSettings
import BBSocketIO
import BBSystem
import BBTooling
import Foundation
import Hummingbird
import Logging

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

/// A started server and the port it is on.
struct ReplayServer {

  let port: Int
  let password: String
  private let listener: HTTPListener
  private let chatDatabasePath: String

  /// Password auth with a known password, which is the shipping default and the mode the
  /// corpus was recorded under. Authentication is left ON rather than disabled: two of the
  /// recorded fixtures are 401s, and a harness that authenticates nobody could not replay
  /// them.
  static let password = "replay-fixture-password"

  static func start() async throws -> ReplayServer {
    // Copied, not opened in place. `ReadOnlyDatabase` will not create the `-wal` companion
    // it needs, and a suite that wrote next to a committed fixture would leave the working
    // tree dirty even when it passed.
    let source = Self.chatDatabaseFixture
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-replay-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)

    let chatDatabase = try ReadOnlyDatabase(path: path.path)
    // 14 — Sonoma, our deployment floor and the schema the fixture was generated from.
    let profile = try await SchemaProfile.detect(in: chatDatabase, osMajorVersion: 14)

    let appDatabase = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let secrets = InMemorySecretStore()
    let settings = try await SettingsStore(database: appDatabase, secrets: secrets)
    try await settings.set(Settings.password, to: Self.password)

    let socketServer = SocketServer()
    let tokenAuth = TokenAuthService()
    let passwordDigests = PasswordDigestCache(
      load: { [settings] in await settings.secret(Settings.password) }
    )

    let context = AppContext(
      appDatabase: appDatabase,
      chatDatabase: chatDatabase,
      settings: settings,
      secrets: secrets,
      schemaProfile: profile,
      messages: MessageRepository(database: chatDatabase, profile: profile),
      contacts: ContactIndex(database: appDatabase),
      serializer: MessageSerializer(profile: profile),
      events: EventBus(),
      // The shipping default. A negotiating server mounts `/message/hydrate` and adds keys
      // to `server/info`, which is precisely the kind of additive surface the diff exists
      // to catch — so the replay must run in the configuration clients actually meet.
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
      logger: Logger(label: "bluebubbles.replay")
    )

    let handlers = await ServerComposition.buildHandlers(
      context: context, authMode: .password, codecs: .legacyOnly()
    )
    await context.finishWiring(
      registry: ServiceRegistry<AppContext>(host: context), handlers: handlers
    )

    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(),
      authentication: AuthenticationStage(
        chain: await tokenAuth.chain(
          passwordProvider: { await passwordDigests.digest() }
        ),
        accessControl: AccessControlService()
      ),
      // Reported as connected. Sixty of the routes are gated on it, and a harness that
      // said "no" would replace every one of their responses with the same 503 — turning
      // the most interesting third of the corpus into one repeated non-finding.
      privateAPI: PrivateAPIStage(isConnected: { true })
    )
    let router = try builder.buildRouter(
      registry: handlers, additionalGroups: context.additionalRouteGroups
    )

    let listener = HTTPListener()
    // Port 0: the kernel picks, and never picks one it has already handed out.
    try await listener.start(router: router, host: "127.0.0.1", port: 0)

    // Optional because a listener that has not started has no port. Here, nil means the
    // start silently did not take — worth a sentence rather than a crash without one.
    guard let bound = await listener.port else { throw ReplayServerError.didNotBind }

    return ReplayServer(
      port: bound,
      password: Self.password,
      listener: listener,
      chatDatabasePath: path.path
    )
  }

  func stop() async {
    await listener.stop()
    try? FileManager.default.removeItem(atPath: chatDatabasePath)
  }

  var baseURL: String { "http://127.0.0.1:\(port)" }

  enum ReplayServerError: Error, CustomStringConvertible {
    case didNotBind
    var description: String {
      "the listener reported no port after starting; it did not actually bind"
    }
  }

  /// Reached by path, like the corpus itself: it belongs to `BBIMessageTests`, which owns
  /// the generator (`Tools/chatdb-fixtures`). Copying it into this target would be a second
  /// copy of a binary fixture to keep in step.
  static let chatDatabaseFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // CompatibilityTests
    .deletingLastPathComponent()  // Tests
    .appendingPathComponent("BBIMessageTests/ChatDBFixtures/chat-sonoma.db")
}
