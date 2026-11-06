//  LiveAppMessageSendTests
//  One real Game Pigeon balloon through a running server's Private API, confirmed in the
//  real `chat.db`.
//
//  Everything else about app balloons stops at a test double for the helper, so nothing else
//  can notice that Messages wrote something other than what the server asked for: no
//  attachment row behind the preview image, a balloon with no bundle id, a `tempGuid` that
//  never came back. The row is the proof, not the server's answer. It is waited for, because
//  Messages writes the message row first and its joins after it.
//
//  Opt in with three variables, read from the environment so no address or password is ever
//  committed, and a run without all three sends nothing:
//
//      BB_LIVE_SERVER_URL=http://127.0.0.1:1234 \
//      BB_LIVE_SERVER_PASSWORD=… \
//      BB_LIVE_SEND_GUID='iMessage;-;someone@example.com' \
//        swift test --filter LiveAppMessageSend
//
//  The server must be one you are running yourself with the Private API connected: the v2
//  app routes answer 402 without a licence and 500 without the helper, and either is
//  reported as itself. This test needs Full Disk Access to read `chat.db`. Each run really
//  sends one Game Pigeon invite with an image from the signed-in account, so run it to answer
//  a question and not in a loop. `RealSenderPolicyTests` holds this file to its gate.

import BBCore
import BBIMessage
import BBPersistence
import BBSerialization
import CoreGraphics
import Foundation
import ImageIO
import Testing

private struct LiveServer: Sendable {
  let url: URL
  let password: String
  let chatGUID: String

  static let fromEnvironment: LiveServer? = {
    let environment = ProcessInfo.processInfo.environment
    guard
      let raw = environment["BB_LIVE_SERVER_URL"], let url = URL(string: raw),
      let password = environment["BB_LIVE_SERVER_PASSWORD"], !password.isEmpty,
      let chat = environment["BB_LIVE_SEND_GUID"], !chat.isEmpty
    else { return nil }
    return LiveServer(url: url, password: password, chatGUID: chat)
  }()
}

private let liveServer = LiveServer.fromEnvironment

@Suite(
  "Live app message send",
  .enabled(
    if: liveServer != nil,
    "Set BB_LIVE_SERVER_URL, BB_LIVE_SERVER_PASSWORD and BB_LIVE_SEND_GUID; sends one invite."
  ))
struct LiveAppMessageSendTests {

  /// How long Messages gets to finish writing the row and its attachment join.
  private static let rowDeadline = Duration.seconds(30)

  /// A complete Cup Pong invite: a short field set arrives and then tells the recipient to
  /// update the app. `sender`, `version`, `tver` and `ios` are the server's to fill in.
  private static func inviteFields(id: String) -> [JSONValue] {
    [
      ("start", ""), ("caption", "BB test game pigeon image"), ("id", id), ("player", "2"),
      ("game", "beer"), ("game_name", "Cup Pong"), ("seed", "\(Int.random(in: 1...99_999))"),
      ("mode", "0"), ("num", "1"), ("style2", "0"),
    ].map { .object(["name": .string($0.0), "value": .string($0.1)]) }
  }

  /// A small solid JPEG, drawn here rather than committed: what is under test is that it
  /// arrives, not how it looks.
  private static func image() throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.13, green: 0.45, blue: 0.30, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let picture = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, picture, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
  }

  @Test("A Game Pigeon invite with an image lands as a balloon carrying the image")
  func sendLandsWithImage() async throws {
    let live = try #require(liveServer)
    let started = Date()
    let stamp = Int(started.timeIntervalSince1970)
    let tempGUID = "bb-live-\(stamp)"
    let session = UUID().uuidString
    // Sixteen characters, like Game Pigeon's own game ids.
    let gameID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
    let image = try Self.image()

    var components = try #require(
      URLComponents(
        url: live.url.appendingPathComponent("api/v2/message/game-pigeon"),
        resolvingAgainstBaseURL: false))
    components.queryItems = [URLQueryItem(name: "password", value: live.password)]
    var request = URLRequest(url: try #require(components.url), timeoutInterval: 90)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: JSONValue = .object([
      "chatGuid": .string(live.chatGUID),
      "version": .int(45),
      "sessionId": .string(session),
      "caption": .string("BB test game pigeon image \(stamp)"),
      "tempGuid": .string(tempGUID),
      "image": .string(image.base64EncodedString()),
      "fields": .array(Self.inviteFields(id: gameID)),
    ])
    request.httpBody = try JSONSerialization.data(withJSONObject: body.foundationObject)

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode
    let reply = try JSONValue.parse(data)
    try #require(status == 200, "the server answered \(status.map(String.init) ?? "nothing")")

    // The reply: the token back, and the session the balloon belongs to.
    let sent = try #require(reply["data"])
    #expect(sent["tempGuid"]?.stringValue == tempGUID)
    #expect(sent["appPayload"]?["session_id"]?.stringValue == session)
    #expect(sent["appPayload"]?["game_pigeon"]?["game_id"]?.stringValue == gameID)
    let guid = try #require(sent["guid"]?.stringValue)

    // The row, and the image joined to it.
    let database = try ReadOnlyDatabase(path: ChatDatabase.defaultPath)
    let repository = MessageRepository(
      database: database,
      profile: try await SchemaProfile.detect(
        in: database, osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion))
    // Waited for until the transfer is FINISHED (state 5) or the row carries an error: the
    // join row arrives first, and a transfer that is going to fail is in it already.
    // MEASURED: a balloon whose image only `fileTransferGUIDs` named landed with
    // `error = 34` and its transfer in state 6, after the server had answered 200.
    let settled = try await poll(.every(.milliseconds(500)), within: Self.rowDeadline) {
      _ -> (IMessageRow, [AttachmentRow])? in
      guard let row = try await repository.message(guid: guid) else { return nil }
      let found = try await repository.attachments(forMessageGUID: guid)
      if row.error != 0 { return (row, found) }
      return found.first?.transferState == 5 && row.isSent ? (row, found) : nil
    }
    let (row, attachments) = try #require(
      settled, "\(guid) neither finished nor failed within \(Self.rowDeadline)")
    #expect(row.error == 0, "Messages refused the send with error \(row.error)")
    #expect(GamePigeonCodec.isGamePigeon(balloonBundleID: row.balloonBundleID))

    // One image, finished and hidden, which is how a genuine Game Pigeon image is stored.
    // Not compared byte for byte: Messages re-encodes it on the way in.
    #expect(attachments.count == 1)
    let joined = try #require(attachments.first)
    #expect(joined.uti == "public.jpeg")
    #expect(joined.transferState == 5)
    #expect(joined.hideAttachment, "the image would draw as a loose attachment under the balloon")
    #expect(joined.totalBytes > 0)
  }
}
