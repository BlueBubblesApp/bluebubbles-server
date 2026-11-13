//  AppSessionThreadingTests
//  A later turn of an iMessage-app session is sent as an update to the session's first
//  message, and the server finds that message itself.
//
//  Messages threads an app's turns through the association columns: type 2 on every turn
//  after the first, pointing at the FIRST turn, and the first rewritten to 3 when one
//  arrives. A turn sent without the link is a balloon of its own on every device. Nothing
//  in a row names a session but the archive, so the lookup decodes the chat's balloons; a
//  client would have to do the same, and a wrong GUID is a move that lands as a new game.
//  These pin what the lookup answers for each shape a session can be in, and that the send
//  hands the helper what it found.
//
//  Balloons are written onto a THROWAWAY copy of the committed fixture; `chat.db` itself is
//  never touched. NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBIMessage
import BBPersistence
import BBPrivateAPIContract
import BBSerialization
import BBTestSupport
import Foundation
import GRDB
import Testing

import struct os.OSAllocatedUnfairLock

@testable import BBInterfaces

@Suite("App session threading", .removingChatDBCopies)
struct AppSessionThreadingTests {

  private static let groupChat = "iMessage;+;chat000000000000000001"
  private static let otherChat = "iMessage;-;+12025550143"
  /// Three rows the fixture joins to the group chat, oldest first.
  private static let firstTurn = "11111111-0000-0000-0000-000000000004"
  private static let secondTurn = "11111111-0000-0000-0000-000000000006"
  private static let ownBalloon = "11111111-0000-0000-0000-000000000007"
  private static let bundle =
    "com.apple.messages.MSMessageExtensionBalloonPlugin:TEAMID123:com.example.game"
  private static let session = UUID(uuidString: "2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22")!
  private static let otherSession = UUID(uuidString: "6086C0E0-1111-4222-8333-944444444444")!

  /// One balloon row as the test wants it written.
  private struct Turn {
    let guid: String
    let session: UUID
    var association: Int = 0
    var origin: String? = nil
  }

  private func open(_ turns: [Turn], helper: MessageInterface.Helper? = nil) async throws
    -> (repository: MessageRepository, interface: MessageInterface)
  {
    let path = try CommittedChatDB.copy()
    let queue = try DatabaseQueue(path: path.path)
    try await queue.write { db in
      for turn in turns {
        let payload = try AppMessagePayload.encode(
          url: "data:?game=pool", sessionID: turn.session, appName: "Game", appID: nil,
          summary: nil, caption: "Your move.")
        try db.execute(
          sql: """
            UPDATE message SET balloon_bundle_id = ?, payload_data = ?,
              associated_message_type = ?, associated_message_guid = ? WHERE guid = ?
            """,
          arguments: [Self.bundle, payload, turn.association, turn.origin, turn.guid])
      }
    }
    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)
    let interface = MessageInterface(
      repository: repository, serializer: MessageSerializer(profile: profile),
      privateAPI: helper, appleScript: InterfaceFixtures.noSender, events: nil)
    return (repository, interface)
  }

  // MARK: - What the lookup answers

  @Test("The earliest turn of the session is the origin")
  func earliestTurnIsTheOrigin() async throws {
    let (repository, _) = try await open([
      Turn(guid: Self.firstTurn, session: Self.session),
      Turn(guid: Self.secondTurn, session: Self.session, association: 2, origin: Self.firstTurn),
    ])
    let origin = try await repository.appSessionOrigin(
      chatGUID: Self.groupChat, bundleID: Self.bundle, sessionID: Self.session)
    #expect(origin == Self.firstTurn)
  }

  @Test("A first turn already rewritten to type 3 is still the origin")
  func rewrittenFirstTurn() async throws {
    let (repository, _) = try await open([
      Turn(guid: Self.firstTurn, session: Self.session, association: 3, origin: Self.firstTurn),
      Turn(guid: Self.secondTurn, session: Self.session, association: 2, origin: Self.firstTurn),
    ])
    let origin = try await repository.appSessionOrigin(
      chatGUID: Self.groupChat, bundleID: Self.bundle, sessionID: Self.session)
    #expect(origin == Self.firstTurn)
  }

  @Test("A first turn deleted locally is still what the thread names")
  func deletedFirstTurn() async throws {
    // Only the second turn is a balloon; it points at a row that is no longer one. The
    // other devices still hold the first turn, so that is what a new turn has to name.
    let (repository, _) = try await open([
      Turn(guid: Self.secondTurn, session: Self.session, association: 2, origin: Self.firstTurn)
    ])
    let origin = try await repository.appSessionOrigin(
      chatGUID: Self.groupChat, bundleID: Self.bundle, sessionID: Self.session)
    #expect(origin == Self.firstTurn)
  }

  @Test("A session the chat has never seen has no origin, and neither has another chat")
  func unknownSession() async throws {
    let (repository, _) = try await open([Turn(guid: Self.firstTurn, session: Self.session)])
    #expect(
      try await repository.appSessionOrigin(
        chatGUID: Self.groupChat, bundleID: Self.bundle, sessionID: Self.otherSession) == nil)
    #expect(
      try await repository.appSessionOrigin(
        chatGUID: Self.otherChat, bundleID: Self.bundle, sessionID: Self.session) == nil)
    // Another app's balloon in the same session id is not this app's session.
    #expect(
      try await repository.appSessionOrigin(
        chatGUID: Self.groupChat, bundleID: Self.bundle + ".other", sessionID: Self.session)
        == nil)
  }

  // MARK: - What the send carries

  private func recordingHelper() -> (
    FailingPrivateAPI, OSAllocatedUnfairLock<SendAppMessageRequest?>
  ) {
    let recorded = OSAllocatedUnfairLock<SendAppMessageRequest?>(initialState: nil)
    var helper = FailingPrivateAPI()
    helper.sentAppMessage = MessageGUID(Self.ownBalloon)
    helper.onAppMessage = { request in recorded.withLock { $0 = request } }
    return (helper, recorded)
  }

  @Test("A send naming a known session hands the helper the first turn, and the live marker")
  func sendCarriesTheOrigin() async throws {
    let (helper, recorded) = recordingHelper()
    let (_, interface) = try await open(
      [Turn(guid: Self.firstTurn, session: Self.session)], helper: helper)

    _ = try await interface.sendAppMessage(
      chatGUID: Self.groupChat, balloonBundleID: Self.bundle, payload: .url("data:?game=pool"),
      sessionID: Self.session.uuidString, liveLayout: true)

    let request = try #require(recorded.withLock { $0 })
    #expect(request.sessionOriginGUID == Self.firstTurn)
    #expect(AppMessagePayload.hasLiveLayout(in: request.payload))
  }

  @Test("A first turn goes out unlinked, whether the session is minted or new")
  func firstTurnIsUnlinked() async throws {
    let (helper, recorded) = recordingHelper()
    let (_, interface) = try await open([], helper: helper)

    _ = try await interface.sendAppMessage(
      chatGUID: Self.groupChat, balloonBundleID: Self.bundle, payload: .url("data:?game=pool"))
    #expect(try #require(recorded.withLock { $0 }).sessionOriginGUID == nil)

    _ = try await interface.sendAppMessage(
      chatGUID: Self.groupChat, balloonBundleID: Self.bundle, payload: .url("data:?game=pool"),
      sessionID: Self.otherSession.uuidString)
    let request = try #require(recorded.withLock { $0 })
    #expect(request.sessionOriginGUID == nil)
    #expect(!AppMessagePayload.hasLiveLayout(in: request.payload))
  }
}
