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
    /// The payload decoded, when it is in one of the shapes this server can read — a
    /// `data:,<base64 JSON>` body, or a query string. A client that wants the raw thing
    /// still has `url`.
    public let payloadJSON: JSONValue?
    public let payloadFields: [(name: String, value: String)]?
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
    // Decoded for the caller when the shape allows. Suppressed for Game Pigeon, whose
    // outer query is just `ver` and the scrambled blob — `game_pigeon` is the real answer
    // and showing both would invite a client to read the wrong one.
    var json: JSONValue?
    var fields: [(name: String, value: String)]?
    if pigeon == nil, let url = envelope.url {
      json = AppPayloadURL.decodeJSON(url).flatMap { try? JSONValue.parse($0) }
      if json == nil { fields = AppPayloadURL.decodeFields(url) }
    }
    return AppMessage(
      guid: row.guid, balloonBundleID: bundleID, appName: envelope.appName,
      appID: envelope.appID, sessionID: envelope.sessionID, summary: envelope.summary,
      caption: envelope.caption, url: envelope.url, gamePigeon: pigeon,
      payloadJSON: json, payloadFields: fields)
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
    if let json = message.payloadJSON { object["payload_json"] = json }
    if let fields = message.payloadFields {
      object["payload_fields"] = .array(
        fields.map { .object(["name": .string($0.name), "value": .string($0.value)]) })
    }
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

  /// The payload a caller wants sent, in whichever shape suits the app.
  ///
  /// A client should not have to know that Polls base64s its JSON into a `data:,` URL while
  /// Game Pigeon uses a query string — so it can hand over the JSON or the fields and let
  /// the server shape it. `url` stays for an app whose format is neither, which is most of
  /// the ones that just link somewhere.
  public enum AppPayload: Sendable {
    case url(String)
    case json(JSONValue)
    case fields([(name: String, value: String)])

    /// Which parts of a poll payload are absent, for the refusal message.
    ///
    /// Only shaped for the `json` case: a poll's payload is base64 JSON, so a `fields`
    /// query string or a raw `url` is not a poll at all and is reported as such. This does
    /// NOT accept a payload as a poll — nothing sent from this route renders as one — it
    /// only makes the error say what is wrong.
    var missingPollFields: [String] {
      switch self {
      case .url: return ["a JSON body — a poll's payload is base64 JSON, not a URL"]
      case .fields:
        return ["a JSON body — a poll's payload is base64 JSON, not a query string"]
      case .json(let value):
        var missing: [String] = []
        if value["version"]?.intValue == nil { missing.append("`version`") }
        guard let item = value["item"] else { return missing + ["`item`"] }
        // A poll payload is one of two shapes: a definition carrying the options, or a
        // vote carrying the selections. Either is legitimate, so neither alone is missing.
        let options = item["orderedPollOptions"]?.arrayValue
        let votes = item["votes"]?.arrayValue
        if options == nil && votes == nil {
          return missing + ["`item.orderedPollOptions` or `item.votes`"]
        }
        if let options {
          if options.isEmpty { missing.append("any option in `item.orderedPollOptions`") }
          for (index, option) in options.enumerated() {
            if option["text"]?.stringValue?.isEmpty ?? true {
              missing.append("`item.orderedPollOptions[\(index)].text`")
            }
            if option["optionIdentifier"]?.stringValue?.isEmpty ?? true {
              missing.append("`item.orderedPollOptions[\(index)].optionIdentifier`")
            }
          }
        }
        if let votes {
          for (index, vote) in votes.enumerated()
          where vote["voteOptionIdentifier"]?.stringValue?.isEmpty ?? true {
            missing.append("`item.votes[\(index)].voteOptionIdentifier`")
          }
        }
        return missing
      }
    }

    func asURL() throws -> String {
      switch self {
      case .url(let url):
        guard !url.isEmpty else {
          throw InterfaceError.invalidRequest("`url` must not be empty")
        }
        return url
      case .json(let value):
        guard
          let data = try? JSONSerialization.data(
            withJSONObject: value.foundationObject, options: [.sortedKeys, .fragmentsAllowed])
        else {
          throw InterfaceError.invalidRequest("`json` could not be encoded")
        }
        return AppPayloadURL.encodeJSON(data)
      case .fields(let fields):
        guard !fields.isEmpty else {
          throw InterfaceError.invalidRequest("`fields` must not be empty")
        }
        return AppPayloadURL.encodeFields(fields)
      }
    }
  }

  /// Balloons this route REFUSES, because sending one from here cannot work.
  ///
  /// This route is deliberately generic: it takes a bundle id and a payload and does not
  /// read the payload. That is right for a third-party app, whose format is its own
  /// business — but it is wrong for a balloon this server builds properly elsewhere, and
  /// the failure is silent. `AppMessagePayload.encode` writes
  /// `layoutClass = MSMessageTemplateLayout`; a poll needs `MSMessageLiveLayout`, which
  /// only the Polls path sets (through ChatKit, on a real `MSMessage`). A poll sent from
  /// here therefore arrives as a bare balloon reading "Sent a poll" with an "Add Choice"
  /// button and NO OPTIONS, whatever its payload says.
  ///
  /// Measured the hard way: two such balloons were sent to a real conversation during
  /// development while testing this route's `json` and `fields` encoders, and they are
  /// still sitting there — past the unsend window, so they cannot be taken back. Refusing
  /// is what stops the next person doing that.
  static func refusal(forBalloon bundleID: String, payload: AppPayload) -> String? {
    guard bundleID == PollsApp.balloonBundleID else { return nil }
    var reason =
      "that is the Polls balloon, and this route cannot produce a poll that renders: it "
      + "writes a template layout, and a poll needs a live layout. Use "
      + "`POST /api/v2/message/poll` — it takes `chatGuid` and `options` and builds the "
      + "payload itself"
    // Said as well as the above, not instead of it: a client debugging this deserves to
    // know the payload was wrong too rather than fixing the route and hitting a second
    // wall.
    let missing = payload.missingPollFields
    if !missing.isEmpty {
      reason +=
        ". This payload is also not a poll — it is missing "
        + missing.joined(separator: ", ")
    }
    return reason
  }

  /// Sends any app balloon. The payload is the app's own and this server does not read it.
  public func sendAppMessage(
    chatGUID: String, balloonBundleID: String, payload: AppPayload, sessionID: String? = nil,
    appName: String? = nil, appID: Int? = nil, summary: String? = nil, caption: String? = nil
  ) async throws -> SendOutcome {
    let url = try payload.asURL()
    let api = try requirePrivateAPI(for: "app messages")
    guard !balloonBundleID.isEmpty else {
      throw InterfaceError.invalidRequest("`balloonBundleId` is required")
    }
    if let refusal = Self.refusal(forBalloon: balloonBundleID, payload: payload) {
      throw InterfaceError.invalidRequest(refusal)
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
  /// The four fields that never vary for a given install, filled in when a caller omits them.
  ///
  /// The server does NOT model games — that is what lets an unknown Game Pigeon game work
  /// without a server change — and these four are not game state. `sender` identifies the
  /// install, `ios` is the sending OS, and `version`/`tver` are format numbers. A client has
  /// no way to know the right answer for any of them, and omitting them is what produces
  /// "You need to update to the latest version of GamePigeon" on the recipient's device: the
  /// app finds no format number where it expects one. Measured — see `docs/GAME_PIGEON.md`
  /// § 4, where a three-field invite produced exactly that while a complete one was played.
  ///
  /// Prepended in the order genuine payloads carry them, and only where the caller said
  /// nothing: a field the caller supplied keeps its own value AND its own position, because
  /// a reply has to echo the `version` it was answering rather than take the invite default.
  public enum GamePigeonBoilerplate {
    /// `5` on every genuine invite seen. A REPLY carries the value it is answering — his
    /// move read `version = 0` — so a client sending one should pass it explicitly.
    public static let payloadVersion = "5"
    /// `5` on every genuine payload seen, invites and moves alike.
    public static let transportVersion = "5"

    /// The sending OS, as Game Pigeon writes it: `14.6`, `26.5.2`.
    public static var osVersion: String {
      let version = ProcessInfo.processInfo.operatingSystemVersion
      return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public static func applied(
      to fields: [(name: String, value: String)], sender: String
    ) -> [(name: String, value: String)] {
      let supplied = Set(fields.map(\.name))
      let boilerplate = [
        ("sender", sender), ("version", payloadVersion),
        ("tver", transportVersion), ("ios", osVersion),
      ]
      // An empty `sender` means the server has not minted one, which should not happen —
      // but writing `sender=` would be worse than leaving the field out, so it is dropped.
      return boilerplate.filter { !supplied.contains($0.0) && !$0.1.isEmpty } + fields
    }
  }

  public func sendGamePigeon(
    chatGUID: String, version: Int, fields: [(name: String, value: String)],
    sessionID: String? = nil, caption: String? = nil, teamID: String = "EWFNLB79LQ",
    senderIdentifier: String = ""
  ) async throws -> SendOutcome {
    guard !fields.isEmpty else {
      throw InterfaceError.invalidRequest("`fields` must not be empty")
    }
    let fields = GamePigeonBoilerplate.applied(to: fields, sender: senderIdentifier)
    let url = GamePigeonCodec.encode(
      GamePigeonCodec.Payload(version: version, fields: fields))
    return try await sendAppMessage(
      chatGUID: chatGUID,
      balloonBundleID:
        "com.apple.messages.MSMessageExtensionBalloonPlugin:\(teamID):\(GamePigeonCodec.extensionSuffix)",
      payload: .url(url), sessionID: sessionID, appName: "GamePigeon",
      appID: GamePigeonCodec.appStoreID, summary: caption, caption: caption)
  }
}
