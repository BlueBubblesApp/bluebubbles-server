//  AppPayloadProjectionTests
//  Where a message carries `appPayload`, and where it must not.
//
//  `appPayload` is an iMessage-app balloon's archive decoded into the object
//  `GET /api/v2/message/app/:guid` answers, put on the message itself so a client rendering a
//  conversation does not fetch once per balloon. It is an addition to a v1 entity, so where it
//  appears is the contract: on a read only when `with` asks for it, always on the send reply
//  and the socket's full payload, never on a notification, and only on an
//  `MSMessageExtensionBalloonPlugin` row. Each of those is a line below.
//
//  The send half also pins `tempGuid` on an app send: the reply echoes it and a `new-message`
//  carrying it is published as soon as the row exists, as a text send does. Without that a
//  client sees the watcher's plain `new-message` first and draws the balloon twice.
//
//  The balloon is written onto a THROWAWAY copy of the committed fixture before the
//  read-only handle opens; `chat.db` itself is never touched. NO REAL ADDRESSES; see
//  CONTRIBUTING.md.

import BBCore
import BBEvents
import BBIMessage
import BBPersistence
import BBPrivateAPIContract
import BBSerialization
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("App payload projection", .removingChatDBCopies)
struct AppPayloadProjectionTests {

  /// A message the account sent, joined to the group chat, so a send hydrates at once.
  private static let balloonGUID = "11111111-0000-0000-0000-000000000007"
  /// A plain text message, left alone.
  private static let plainGUID = "11111111-0000-0000-0000-000000000001"

  private static let gamePigeonBundle =
    "com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:"
    + GamePigeonCodec.extensionSuffix
  private static let session = "2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22"

  private static var pigeonURL: String {
    GamePigeonCodec.encode(
      GamePigeonCodec.Payload(
        version: 45,
        fields: [(name: "game", value: "beer"), (name: "id", value: "game0000000000001")]))
  }

  /// The interface over a fixture copy whose `balloonGUID` row is a Game Pigeon balloon.
  private func interface(
    bundleID: String = gamePigeonBundle,
    privateAPI: MessageInterface.Helper? = nil,
    events: EventBus? = nil
  ) async throws -> MessageInterface {
    let path = try CommittedChatDB.copy()
    let payload = try AppMessagePayload.encode(
      url: Self.pigeonURL, sessionID: try #require(UUID(uuidString: Self.session)),
      appName: "GamePigeon", appID: GamePigeonCodec.appStoreID, summary: "Cup Pong",
      caption: "Let's play Cup Pong!")
    let queue = try DatabaseQueue(path: path.path)
    try await queue.write { db in
      try db.execute(
        sql: "UPDATE message SET balloon_bundle_id = ?, payload_data = ? WHERE guid = ?",
        arguments: [bundleID, payload, Self.balloonGUID])
    }

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    return MessageInterface(
      repository: MessageRepository(database: database, profile: profile),
      serializer: MessageSerializer(profile: profile),
      privateAPI: privateAPI,
      appleScript: InterfaceFixtures.noSender,
      events: events
    )
  }

  private func read(
    _ guid: String, from interface: MessageInterface, withAppPayload: Bool
  ) async throws -> JSONValue {
    let query = MessageInterface.Query(withAppPayload: withAppPayload)
    let message = try #require(try await interface.find(guid: guid, query: query))
    return interface.serialize(message, query: query)
  }

  // MARK: - Reads

  @Test("A read carries appPayload only when `with` asks for it")
  func readIsOptIn() async throws {
    let interface = try await interface()

    // Default: byte-for-byte what the reference sends, which has no such key.
    let unasked = try await read(Self.balloonGUID, from: interface, withAppPayload: false)
    #expect(unasked["appPayload"] == nil)

    let asked = try await read(Self.balloonGUID, from: interface, withAppPayload: true)
    let app = try #require(asked["appPayload"])
    #expect(app["session_id"]?.stringValue == Self.session)
    #expect(app["url"]?.stringValue == Self.pigeonURL)
    #expect(app["app_name"]?.stringValue == "GamePigeon")
    #expect(app["balloon_bundle_id"]?.stringValue == Self.gamePigeonBundle)
    // Decoded, so the client does not repeat the scramble.
    #expect(app["game_pigeon"]?["game"]?.stringValue == "beer")
  }

  @Test("It is the same object GET message/app/:guid answers")
  func sameObjectAsTheAppRoute() async throws {
    let interface = try await interface()
    let asked = try await read(Self.balloonGUID, from: interface, withAppPayload: true)
    let route = interface.serialize(try await interface.appMessage(guid: Self.balloonGUID))
    #expect(asked["appPayload"] == route)
  }

  @Test("A message that is not an app balloon gains nothing, even when asked")
  func plainMessageUntouched() async throws {
    let interface = try await interface()
    let plain = try await read(Self.plainGUID, from: interface, withAppPayload: true)
    #expect(plain["appPayload"] == nil)
    #expect(plain["guid"]?.stringValue == Self.plainGUID)
  }

  @Test("A built-in balloon is never decoded as an app, whatever its archive holds")
  func builtInBalloonUntouched() async throws {
    // A rich link is not an iMessage app. Even handed an `MSMessage` archive, a row whose
    // bundle id is a built-in provider is left alone: the projection keys on the bundle id,
    // which is also what keeps the archive read off every rich-link row of a page.
    let interface = try await interface(bundleID: "com.apple.messages.URLBalloonProvider")
    let row = try await read(Self.balloonGUID, from: interface, withAppPayload: true)
    #expect(row["appPayload"] == nil)
  }

  @Test("`with` takes appPayload in either spelling, and payloadData does not imply it")
  func relationSpellings() throws {
    for spelling in ["appPayload", "app-payload", "message.appPayload"] {
      let query = try MessageInterface.Query.parse(
        .object(["with": .array([.string(spelling)])]))
      #expect(query.withAppPayload, "\(spelling)")
    }
    let raw = try MessageInterface.Query.parse(.object(["with": .array([.string("payloadData")])]))
    #expect(!raw.withAppPayload)
    #expect(raw.withPayloadData)
  }

  // MARK: - Sends

  /// A bus with one socket-shaped and one push-shaped recorder on it.
  private func recordingBus() async -> (EventBus, socket: RecordingSink, push: RecordingSink) {
    let bus = EventBus()
    let socket = RecordingSink(id: .socket, projection: .full)
    let push = RecordingSink(id: .push, projection: .notification)
    await bus.register(socket)
    await bus.register(push)
    return (bus, socket, push)
  }

  @Test("An app send answers with appPayload and announces its tempGuid on the socket only")
  func sendCarriesBoth() async throws {
    var helper = FailingPrivateAPI()
    helper.sentAppMessage = MessageGUID(Self.balloonGUID)
    let (bus, socket, push) = await recordingBus()
    let interface = try await interface(privateAPI: helper, events: bus)

    let outcome = try await interface.sendAppMessage(
      chatGUID: "iMessage;+;chat000000000000000001", balloonBundleID: Self.gamePigeonBundle,
      payload: .url(Self.pigeonURL), sessionID: Self.session, tempGUID: "TEMP-APP")
    await bus.settle()

    // The reply: how a client that let the server mint the session learns it.
    let reply = interface.serialize(outcome, tempGUID: "TEMP-APP")
    #expect(reply["tempGuid"]?.stringValue == "TEMP-APP")
    #expect(reply["appPayload"]?["session_id"]?.stringValue == Self.session)

    // The matched `new-message`, on both sinks, carrying the token.
    #expect(await socket.names() == [.newMessage])
    #expect(await push.names() == [.newMessage])
    let full = try #require(await socket.payloads.first)
    let notification = try #require(await push.payloads.first)
    #expect(full["tempGuid"]?.stringValue == "TEMP-APP")
    #expect(notification["tempGuid"]?.stringValue == "TEMP-APP")
    // The decoded payload on the socket, never on a notification: FCM's 4 KB is spent.
    #expect(full["appPayload"]?["url"]?.stringValue == Self.pigeonURL)
    #expect(notification["appPayload"] == nil)
  }

  @Test("An app send with no tempGuid announces nothing of its own")
  func sendWithoutTempGUID() async throws {
    var helper = FailingPrivateAPI()
    helper.sentAppMessage = MessageGUID(Self.balloonGUID)
    let (bus, socket, _) = await recordingBus()
    let interface = try await interface(privateAPI: helper, events: bus)

    _ = try await interface.sendAppMessage(
      chatGUID: "iMessage;+;chat000000000000000001", balloonBundleID: Self.gamePigeonBundle,
      payload: .url(Self.pigeonURL))
    await bus.settle()

    // The watcher's plain `new-message` is the only one; there is nothing to match.
    #expect(await socket.names().isEmpty)
  }
}
