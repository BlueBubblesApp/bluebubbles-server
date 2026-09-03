//  AppMessageInterface
//  Reading and sending iMessage-app balloons, Game Pigeon included.
//
//  One generic pair of operations, because every iMessage app works the same way: the
//  message carries a plugin bundle id and an archived `MSMessage` whose `URL` is whatever
//  the app decided. Polls has its own routes because the server understands poll state;
//  everything else is passed through, and the CLIENT decides what a payload means.
//
//  Game Pigeon gets one extra convenience — the `data:` URL it uses is a scrambled query
//  string, and no client should have to reimplement that shuffle. What the server does NOT
//  do is model games: `fields` goes out and comes back as an ordered list of name/value
//  pairs, so 8 Ball's physics replay and Word Hunt's letter grid travel equally well.
//  `docs/GAME_PIGEON.md` is the reference.

import BBIMessage
import BBPrivateAPIContract
import BBSerialization
import Foundation

extension MessageInterface {

  /// An app balloon as this server understands it.
  public struct AppMessage: Sendable {
    public let guid: String
    public let balloonBundleID: String?
    public let appName: String?
    public let appID: Int?
    public let sessionID: String?
    public let summary: String?
    public let caption: String?
    /// The app's own payload, exactly as it was sent. A client that understands the app
    /// better than this server does can work from this alone.
    public let url: String?
    /// Decoded Game Pigeon fields, when the message is one.
    public let gamePigeon: GamePigeonCodec.Payload?
  }

  public func appMessage(guid: String) async throws -> AppMessage {
    let row = try await requireMessage(guid)
    guard let bundleID = row.balloonBundleID, !bundleID.isEmpty else {
      throw InterfaceError.invalidRequest("\(guid) is not an app message")
    }
    guard let envelope = AppMessagePayload.envelope(from: row.payloadData) else {
      // MEASURED across every balloon type on a real Mac: the `MSMessageExtensionBalloonPlugin`
      // ones all carry an `MSMessage` archive and decode here, Apple's built-in balloon
      // PROVIDERS do not, because they are not iMessage apps and each has its own format —
      // a rich link is an archived `RichLink`/`LPLinkMetadata`, and Digital Touch and
      // handwriting are not property lists at all. Saying which it is beats "no payload".
      throw InterfaceError.invalidRequest(
        Self.unreadablePayloadReason(bundleID: bundleID, guid: guid))
    }
    let pigeon =
      GamePigeonCodec.isGamePigeon(balloonBundleID: bundleID)
      ? envelope.url.flatMap(GamePigeonCodec.decode(url:))
      : nil
    return AppMessage(
      guid: row.guid, balloonBundleID: bundleID, appName: envelope.appName,
      appID: envelope.appID, sessionID: envelope.sessionID, summary: envelope.summary,
      caption: envelope.caption, url: envelope.url, gamePigeon: pigeon)
  }

  /// Why a balloon could not be read, in terms a client can act on.
  static func unreadablePayloadReason(bundleID: String, guid: String) -> String {
    if !bundleID.contains("MSMessageExtensionBalloonPlugin") {
      let alternative =
        bundleID.contains("Handwriting") || bundleID.contains("DigitalTouch")
        ? " Its rendered media is available from `GET /message/:guid/embedded-media`."
        : bundleID.contains("URLBalloonProvider")
          ? " Its link metadata is in the message's own `payloadData`, with `?with=payloadData`."
          : ""
      return
        "\(guid) is a built-in balloon (\(bundleID)), not an iMessage app, so it has no app "
        + "payload to decode." + alternative
    }
    return
      "\(guid) carries no readable app payload — the attachment may not have been downloaded yet"
  }

  public func serialize(_ message: AppMessage) -> JSONValue {
    var object: [String: JSONValue] = [
      "guid": .string(message.guid),
      "balloon_bundle_id": message.balloonBundleID.map(JSONValue.string) ?? .null,
      "app_name": message.appName.map(JSONValue.string) ?? .null,
      "app_id": message.appID.map(JSONValue.int) ?? .null,
      "session_id": message.sessionID.map(JSONValue.string) ?? .null,
      "summary": message.summary.map(JSONValue.string) ?? .null,
      "caption": message.caption.map(JSONValue.string) ?? .null,
      "url": message.url.map(JSONValue.string) ?? .null,
    ]
    if let pigeon = message.gamePigeon {
      object["game_pigeon"] = .object([
        "version": .int(pigeon.version),
        "game": pigeon.game.map(JSONValue.string) ?? .null,
        "game_id": pigeon.gameID.map(JSONValue.string) ?? .null,
        // An ORDERED list, not a map: a repeated name is legal in a query string and some
        // games rely on the order. A client wanting a map can build one.
        "fields": .array(
          pigeon.fields.map { .object(["name": .string($0.name), "value": .string($0.value)]) }),
      ])
    }
    return .object(object)
  }

  /// Sends any app balloon. `url` is the app's payload and this server does not read it.
  public func sendAppMessage(
    chatGUID: String, balloonBundleID: String, url: String, sessionID: String? = nil,
    appName: String? = nil, appID: Int? = nil, summary: String? = nil, caption: String? = nil
  ) async throws -> SendOutcome {
    let api = try requirePrivateAPI(for: "app messages")
    guard !balloonBundleID.isEmpty else {
      throw InterfaceError.invalidRequest("`balloonBundleId` is required")
    }
    // A new session unless the caller is continuing one. Game Pigeon threads a game
    // through the session, so a reply MUST carry the session it is answering.
    let session = sessionID.flatMap(UUID.init(uuidString:)) ?? UUID()
    let payload: Data
    do {
      payload = try AppMessagePayload.encode(
        url: url, sessionID: session, appName: appName, appID: appID, summary: summary,
        caption: caption)
    } catch let error as AppMessageError {
      throw InterfaceError.invalidRequest(error.description)
    }
    let sent = try await throughMessages {
      try await api.sendAppMessage(
        SendAppMessageRequest(
          chat: ChatIdentifier(chatGUID), balloonBundleID: balloonBundleID, payload: payload,
          summary: summary ?? caption))
    }
    return SendOutcome(
      backend: .privateAPI, messageGUID: sent.guid.rawValue,
      message: try await awaitSentMessage(guid: sent.guid.rawValue))
  }

  /// Sends a Game Pigeon message from its fields, doing the scramble for the caller.
  ///
  /// `teamID` is part of the balloon bundle id and belongs to the developer, so it is taken
  /// from the message being answered where there is one, and defaults to Game Pigeon's own.
  public func sendGamePigeon(
    chatGUID: String, version: Int, fields: [(name: String, value: String)],
    sessionID: String? = nil, caption: String? = nil, teamID: String = "EWFNLB79LQ"
  ) async throws -> SendOutcome {
    guard !fields.isEmpty else {
      throw InterfaceError.invalidRequest("`fields` must not be empty")
    }
    let url = GamePigeonCodec.encode(
      GamePigeonCodec.Payload(version: version, fields: fields))
    return try await sendAppMessage(
      chatGUID: chatGUID,
      balloonBundleID:
        "com.apple.messages.MSMessageExtensionBalloonPlugin:\(teamID):\(GamePigeonCodec.extensionSuffix)",
      url: url, sessionID: sessionID, appName: "GamePigeon",
      appID: GamePigeonCodec.appStoreID, summary: caption, caption: caption)
  }
}
