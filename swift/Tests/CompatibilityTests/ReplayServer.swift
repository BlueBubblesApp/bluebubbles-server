//  ReplayServer
//  The real server, in this process, over a synthetic `chat.db`.
//
//  Every other harness in the suite mounts a throwaway route table with one handler in it,
//  which is right for what those suites test: routing, the envelope, path parameters. This
//  one mounts the SHIPPING registry: `ServerComposition.buildHandlers`, the same call the
//  running server makes, so what the replay diffs is what a client would receive.
//
//  The database is `Tests/BBIMessageTests/ChatDBFixtures/chat-sonoma.db`, reached by path.
//  An empty database would answer every read with an empty array, and an empty array is
//  exactly the case a shape diff cannot see into: the corpus's whole value is the entity
//  fields inside `data`, and three chats with seven messages between them is what makes
//  those fields exist to compare.

import BBAuth
import BBContacts
import BBDiagnostics
import BBEvents
import BBHTTPAPI
import BBIMessage
import BBPersistence
import BBPrivateAPIContract
import BBSerialization
import BBServiceKit
import BBSettings
import BBSocketIO
import BBSystem
import BBTestSupport
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
    // 14: Sonoma, our deployment floor and the schema the fixture was generated from.
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

    let logger = Logger(label: "bluebubbles.replay")
    let context = AppContext(
      storage: ServerComposition.Storage(
        logSink: FileSink(url: path.appendingPathExtension("log")),
        logger: logger, appDatabase: appDatabase, secrets: secrets, settings: settings
      ),
      readPath: ServerComposition.ReadPath(
        database: chatDatabase,
        profile: profile,
        messages: MessageRepository(database: chatDatabase, profile: profile),
        serializer: MessageSerializer(profile: profile)
      ),
      shared: ServerComposition.SharedServices(
        alerts: AlertCenter(),
        permissions: PermissionsService(),
        accessControl: AccessControlService(),
        contacts: ContactIndex(database: appDatabase)
      ),
      transport: ServerComposition.Transport(
        authMode: .password,
        // The shipping default. A negotiating server mounts `/message/hydrate` and adds
        // keys to `server/info`, which is precisely the kind of additive surface the diff
        // exists to catch, so the replay must run in the configuration clients actually
        // meet.
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

    // A HELPER THAT ANSWERS, so the sixty Private-API routes are shape-diffed rather than
    // reduced to one repeated refusal.
    //
    // The stage below already reports `isConnected: true`, which gets a request PAST the
    // gate; without a published client it then died inside the handler on
    // `requirePrivateAPI`, so every helper-backed fixture sat in the baseline as
    // "HARNESS: needs the Private API helper" and its recorded shape was compared to
    // nothing. Two of them had drifted in exactly the way the corpus would have shown:
    // `icloud/account` lost four keys and retyped two, and `share-contact-status` wrapped a
    // bare boolean in an object.
    //
    // Only the five reads the corpus recorded a 200 for are answered. Everything else keeps
    // throwing, which is deliberate: three of the helper fixtures record a 500 from the
    // REFERENCE, and a stub that succeeded there would manufacture a difference instead of
    // finding one.
    var helper = FailingPrivateAPI()
    helper.onAccountInfo = {
      AccountInfo(
        appleId: "person@example.com",
        accountName: "Replay Fixture",
        activeAlias: "person@example.com",
        aliases: [AccountAlias(alias: "person@example.com", status: 3, isUserVisible: true)],
        vettedAliases: [
          AccountAlias(alias: "person@example.com", status: 3, isUserVisible: true)
        ],
        loginStatusMessage: "Connected",
        smsForwardingEnabled: false,
        smsForwardingCapable: false
      )
    }
    // A REAL FILE, because the handler reads the avatar off disk itself and omits the key
    // when it cannot. The recorded card has one, so a nil path here would report a missing
    // `data.avatar` forever — a harness artefact indistinguishable, in the diff, from this
    // server having dropped the field. The bytes are irrelevant: `.shape` compares which
    // keys exist and their types, not what is in them.
    let avatar = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-replay-avatar-\(UUID().uuidString).png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: avatar)
    let avatarPath = avatar.path
    helper.onNicknameInfo = { _ in
      NicknameInfo(
        handle: nil, name: "Replay Fixture", hasSharedNickname: true, avatarPath: avatarPath)
    }
    helper.onIMessageAvailability = { _ in true }
    helper.onFaceTimeAvailability = { _ in true }
    helper.onShouldOfferNicknameSharing = { _ in false }
    await context.publishPrivateAPI(client: helper, runtime: nil)

    // A REAL LOG SINK, for the same reason as the helper above: without one the route
    // answers 503 and its recorded shape is compared to nothing. It was, and the route was
    // sending an array of lines where the reference sends one string — which the app feeds
    // to `File.writeAsString` and then swallows the type error from.
    //
    // Written to a temporary file with a couple of lines in it, because `tail` of an empty
    // file is an empty string and an empty string cannot show that the value is text.
    let logFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-replay-log-\(UUID().uuidString).log")
    try "[replay] first line\n[replay] second line\n".write(
      to: logFile, atomically: true, encoding: .utf8)
    let logSink = FileSink(url: logFile)

    let handlers = await ServerComposition.buildHandlers(
      context: context, authMode: .password, codecs: .legacyOnly(), logSink: logSink
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
      // said "no" would replace every one of their responses with the same 503, turning
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
    // start silently did not take: worth a sentence rather than a crash without one.
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
    try? FileManager.default.removeItem(atPath: chatDatabasePath + ".log")
  }

  var baseURL: String { "http://127.0.0.1:\(port)" }

  /// Creates the entities the corpus's DELETE and single-entity fixtures expect to find.
  ///
  /// `app.db` is `AppDatabase.inMemory`, so every run starts with nothing in it and four
  /// recorded 200s answered 404 here: the theme and settings backups their bodies name, the
  /// scheduled message `GET /message/schedule/4` asks for, and the contact
  /// `DELETE /contact/555` deletes. A 404 against a 200 means the diff compares two error
  /// envelopes and the recorded shape is never looked at, which is how
  /// `DELETE /contact/:id` kept a 404 where the reference answers 400.
  ///
  /// Seeded THROUGH THE API rather than by writing rows, so what the fixtures then read is
  /// what a client would have created. It also keeps this harness ignorant of the storage
  /// layer, which is the property that let the chat.db half of the corpus survive a schema
  /// change.
  ///
  /// Best effort per entity: a seed that fails leaves its fixture answering 404, which is
  /// the state it was already in and is recorded in the baseline. It must not take the
  /// whole replay down.
  func seedRecordedEntities() async {
    await post("/api/v1/backup/theme", ["name": "Fixture Theme", "data": ["seeded": true]])
    await post("/api/v1/backup/settings", ["name": "Fixture Settings", "data": ["seeded": true]])
    await post(
      "/api/v1/message/schedule",
      [
        "type": "send-message",
        "payload": [
          "chatGuid": "iMessage;-;+12025550143",
          "message": "Fixture scheduled message",
          "method": "apple-script",
        ],
        // Far enough out that the scheduler will not fire it during a replay.
        "scheduledFor": Int(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000),
        "schedule": ["type": "once"],
      ])
  }

  private func post(_ path: String, _ body: [String: Any]) async {
    guard var components = URLComponents(string: baseURL + path) else { return }
    components.queryItems = [URLQueryItem(name: "password", value: password)]
    guard let url = components.url,
      let payload = try? JSONSerialization.data(withJSONObject: body)
    else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = payload
    _ = try? await URLSession.shared.data(for: request)
  }

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
