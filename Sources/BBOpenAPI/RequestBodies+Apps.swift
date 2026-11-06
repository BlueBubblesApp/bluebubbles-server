//  RequestBodies+Apps
//  The bodies of the iMessage app routes: polls, app balloons and Game Pigeon.
//
//  Its own file so a reader of what an app payload looks like opens the two helpers that
//  shape one beside the bodies that use them. The declaration model, the rules and
//  `byHandler` are in `RequestBodies.swift`.

import BBHTTPAPI

extension RequestBodies {

  /// The balloon's image, on both send routes.
  private static let appPreviewImage = Property(
    "image", .string,
    "The balloon's image, base64 (a `data:image/…;base64,` prefix is accepted): the "
      + "picture the layout shows, such as the game board. JPEG, PNG or HEIC, at most 4 MB; send a "
      + "thumbnail. It travels as a hidden attachment on the balloon message, as a genuine "
      + "one does. Not the app icon, which the server supplies.")

  /// The live-layout marker, on both send routes.
  private static let appLiveLayout = Property(
    "liveLayout", .boolean,
    "Mark the balloon LIVE, so the recipient's extension draws its own view in the transcript "
      + "rather than the caption and icon. Every message a current Game Pigeon sends carries "
      + "it; without it a Game Pigeon turn arrives as a template balloon. Default false.")

  /// The same correlation token, and the same deduplication, as `message/multipart`.
  private static let appTempGUID = Property(
    "tempGuid", .string,
    "Client-generated id echoed back on the sent message and on the `new-message` event "
      + "that matches it, so a client can swap its placeholder for the real row. Also the "
      + "deduplication key: a second send under a `tempGuid` still in flight is refused.")

  private static let appPayloadFields = Property(
    "fields",
    .array(
      of: .object(properties: [
        Property("name", .string, "The field's name.", required: true),
        Property("value", .string, "Its value. An empty string is a real value.", required: true),
      ])),
    "The payload as a query string, in order. A plain object is accepted too when order "
      + "does not matter.")

  /// Merged into `byHandler`.
  static let appBodies: [HandlerID: Body] = [
    // MARK: Polls

    .messageCreatePoll: Body(
      summary: "Sends a new poll. macOS 26 and newer.",
      properties: [
        chatGUID(),
        appTempGUID,
        Property(
          "options", .array(of: .string),
          "The choices, in order. At least two, none empty.", required: true),
        Property(
          "title", .string,
          "Accepted and sent, but Messages 26 neither shows a poll title nor keeps one; its "
            + "own updates clear the field. Do not build UI on it."),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("options", .array([.string("Pizza"), .string("Sushi"), .string("Either")])),
      ])),

    .messageVotePoll: Body(
      summary: "Casts this account's vote. The selection is complete, not a delta.",
      properties: [
        chatGUID("The conversation the poll is in."),
        appTempGUID,
        Property(
          "optionIds", .array(of: .string),
          "Every option this account is voting for. An empty array retracts every vote. Each "
            + "id must be an option on the poll.", required: true),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("optionIds", .array([.string("16D8D418-28B5-4606-8A71-98C28D556B9C")])),
      ])),

    .messageAddPollOption: Body(
      summary: "Adds a choice, which re-sends the poll in its new state.",
      properties: [
        chatGUID("The conversation the poll is in."),
        appTempGUID,
        Property("text", .string, "The choice to add.", required: true),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")), ("text", .string("Thai")),
      ])),

    // MARK: iMessage app balloons

    .messageSendApp: Body(
      summary:
        "Sends an iMessage app's balloon. Supply the payload in whichever shape fits. A "
        + "`sessionId` the chat already holds a balloon for makes this a turn in that "
        + "session, linked to its first message so Messages threads them into one balloon. "
        + "The Polls balloon is REFUSED here, because a poll sent this way does not render as "
        + "one; use POST message/poll.",
      properties: [
        chatGUID(),
        appTempGUID,
        Property(
          "balloonBundleId", .string,
          "The app's full balloon bundle id, including the "
            + "`com.apple.messages.MSMessageExtensionBalloonPlugin:<team>:` prefix.",
          required: true),
        Property(
          "json", .anything,
          "The payload as JSON, sent as a `data:,<base64>` URL. One of `json`, `fields` or "
            + "`url` is required."),
        appPayloadFields,
        Property(
          "url", .string,
          "The payload URL verbatim, for an app whose format is neither of the above; an "
            + "https link, or a `data:` URL with a media type."),
        Property(
          "sessionId", .string,
          "The `MSSession` UUID. Omit to start a new one; pass the session of the message "
            + "being answered to continue a conversation."),
        Property("appName", .string, "The app's display name, shown on the balloon."),
        Property("appId", .integer, "The app's App Store id."),
        Property("caption", .string, "The line shown where the balloon cannot be drawn."),
        appPreviewImage,
        appLiveLayout,
        Property("summary", .string, "The message's fallback summary text."),
      ],
      // A THIRD-PARTY app, deliberately. The obvious example to reach for is Polls, and
      // Polls is the one balloon this route refuses: an example the server would reject
      // is worse than no example.
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        (
          "balloonBundleId",
          .string(
            "com.apple.messages.MSMessageExtensionBalloonPlugin:QPU8QS3E62"
              + ":com.contextoptional.OpenTable.Messages"
          )
        ),
        ("appName", .string("OpenTable")),
        ("caption", .string("Table for two, 7pm")),
        (
          "fields",
          .array([
            field("restaurant", "12345"),
            field("time", "19:00"),
          ])
        ),
      ])),

    .messageSendGamePigeon: Body(
      summary:
        "Sends a Game Pigeon message, doing its payload scramble for you. `sender`, "
        + "`version`, `tver` and `ios` are filled in when absent; everything else is yours, "
        + "and a SHORT field set arrives, renders, and then tells the recipient to update "
        + "GamePigeon. Capture a real invite with GET message/app/:guid and vary it.",
      properties: [
        chatGUID(),
        appTempGUID,
        appPayloadFields,
        Property(
          "version", .integer,
          "Game Pigeon's own payload version, the `ver=` on the payload URL. Echo back the "
            + "one you received; defaults to 52. Genuine invites carry 45 through 50 "
            + "depending on the game and how old the sending app is."),
        Property(
          "sessionId", .string,
          "The `MSSession` UUID of the game being continued. Omit only for a new invite. A "
            + "move is then sent as a turn in the game, linked to the invite, and the "
            + "transcript shows one balloon rather than one per move."),
        Property("caption", .string, "The line shown on the balloon, e.g. `Your move.`"),
        appPreviewImage,
        appLiveLayout,
        Property(
          "teamId", .string,
          "The developer team id in the balloon bundle id. Defaults to Game Pigeon's own."),
      ],
      // A COMPLETE field set, modelled on an invite that was actually opened and played. A
      // three-field example makes a recipient's app say "You need to update to the latest
      // version of GamePigeon".
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("version", .int(45)),
        ("sessionId", .string("2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22")),
        ("caption", .string("Let's play Cup Pong!")),
        (
          "fields",
          .array([
            field("sender", "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"),
            field("version", "5"),
            field("tver", "5"),
            field("ios", "26.5.2"),
            field("start", ""),
            field("caption", "Let's play Cup Pong!"),
            field("id", "frWzzfHEQ8COyfyp"),
            field("player", "2"),
            field("player2", "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"),
            field("game", "beer"),
            field("game_name", "Cup Pong"),
            field("seed", "947177914"),
            field("mode", "n"),
            field("style2", "0"),
            field("num", "1"),
          ])
        ),
      ])),

  ]

  /// One `fields` entry of a Game Pigeon example: the name/value pair every entry is.
  private static func field(_ name: String, _ value: String) -> OrderedJSON {
    .obj([("name", .string(name)), ("value", .string(value))])
  }
}
