//  RequestBodies
//  JSON request bodies that inference cannot produce, written by hand.
//
//  Every other schema in the document is INFERRED from recorded fixtures, which is the right
//  default: a schema derived from a real payload cannot describe a field the server does not
//  actually accept. But inference needs a recording, and the conformance recorder replays
//  against the Node server — so a route that only exists here has no fixture, no inferred
//  body, and lands in the document as a path with no documented input at all. A client author
//  reading that has nothing to go on.
//
//  So these are declared, the same way `MultipartBodies` declares the file uploads for the
//  same reason. Two rules keep them honest, both enforced by `RequestBodyTests`:
//
//  1. A declaration WINS over an inferred body, because it is the more complete description —
//     but for a route that does have a fixture it must be a SUPERSET of what was inferred.
//     That makes a declaration able to add a field the reference never had, and unable to
//     quietly drop one that was really recorded.
//  2. Every property carries a description, and every body carries an `example`. The example
//     is the point of the exercise: it is what a client author copies.
//
//  See `docs/api/README.md` § Request bodies.

import BBHTTPAPI

public enum RequestBodies {

  /// A property's shape. Deliberately small — these are request bodies, not a type system.
  public indirect enum Schema: Sendable {
    case string
    case integer
    case number
    case boolean
    /// Free-form: any JSON the caller likes, which is what an app payload is.
    case anything
    case array(of: Schema)
    case object(properties: [Property])

    var typeName: String? {
      switch self {
      case .string: "string"
      case .integer: "integer"
      case .number: "number"
      case .boolean: "boolean"
      case .array: "array"
      case .object: "object"
      case .anything: nil
      }
    }
  }

  public struct Property: Sendable {
    public let name: String
    public let schema: Schema
    public let description: String
    public let isRequired: Bool

    public init(
      _ name: String, _ schema: Schema, _ description: String, required: Bool = false
    ) {
      self.name = name
      self.schema = schema
      self.description = description
      self.isRequired = required
    }
  }

  public struct Body: Sendable {
    public let summary: String
    public let properties: [Property]
    /// What a caller can copy and send. Rendered as the operation's `example`.
    public let example: OrderedJSON
    /// False where every field is optional, so the route works with no body at all.
    public let isRequired: Bool

    public init(
      summary: String, properties: [Property], example: OrderedJSON, required: Bool = true
    ) {
      self.summary = summary
      self.properties = properties
      self.example = example
      self.isRequired = required
    }
  }

  /// The field every write route takes, so the description is written once.
  private static func chatGUID(_ note: String = "The conversation to send to.") -> Property {
    Property("chatGuid", .string, note, required: true)
  }

  private static let textFormatting = Property(
    "textFormatting",
    .array(
      of: .object(properties: [
        Property("start", .integer, "Offset in UTF-16 code units.", required: true),
        Property("length", .integer, "Length in UTF-16 code units.", required: true),
        Property(
          "styles", .array(of: .string),
          "Any of `bold`, `italic`, `underline`, `strikethrough`."),
        Property(
          "effect", .string,
          "One of `big`, `small`, `shake`, `nod`, `explode`, `ripple`, `bloom`, `jitter`."),
      ])),
    "Inline styles and animated effects, by range. A range needs a style or an effect. "
      + "Private API only, macOS 15 and newer.")

  private static let appPayloadFields = Property(
    "fields",
    .array(
      of: .object(properties: [
        Property("name", .string, "The field's name.", required: true),
        Property("value", .string, "Its value. An empty string is a real value.", required: true),
      ])),
    "The payload as a query string, in order. A plain object is accepted too when order "
      + "does not matter.")

  public static let byHandler: [HandlerID: Body] = [

    // MARK: v1 routes that grew fields this server's fixtures predate

    .messageSendText: Body(
      summary: "Sends a text message.",
      properties: [
        chatGUID(),
        Property("message", .string, "The text to send.", required: true),
        Property(
          "tempGuid", .string,
          "Client-generated id echoed back on the sent message, so a client can match the "
            + "response to the row it inserted optimistically. Required for AppleScript.",
          required: true),
        Property(
          "method", .string,
          "`apple-script` or `private-api`. AppleScript needs no helper; the Private API is "
            + "required for subjects, effects, replies and formatting.", required: true),
        Property("subject", .string, "Subject line. Private API only."),
        Property(
          "effectId", .string,
          "A send effect, e.g. `com.apple.MobileSMS.expressivesend.impact`. Private API only."),
        Property(
          "selectedMessageGuid", .string,
          "The message this one replies to, threading it. Private API only."),
        Property("partIndex", .integer, "Which part of the replied-to message. Defaults to 0."),
        Property("ddScan", .boolean, "Scan the text for links and data detectors."),
        textFormatting,
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("tempGuid", .string("6E2C1A2B-0F2E-4E77-9B6C-2E5A3D9F1A44")),
        ("message", .string("bold and shaking")),
        ("method", .string("private-api")),
        (
          "textFormatting",
          .array([
            .obj([
              ("start", .int(0)), ("length", .int(4)), ("styles", .array([.string("bold")])),
            ]),
            .obj([("start", .int(9)), ("length", .int(8)), ("effect", .string("shake"))]),
          ])
        ),
      ])),

    .messageReact: Body(
      summary: "Sends a tapback, including an emoji one.",
      properties: [
        chatGUID("The conversation the target message is in."),
        Property(
          "selectedMessageGuid", .string, "The message being reacted to.", required: true),
        Property(
          "reaction", .string,
          "`love`, `like`, `dislike`, `laugh`, `emphasize`, `question` or `emoji`, each with "
            + "a `-` prefix to remove it (`-love`, `-emoji`).", required: true),
        Property(
          "emoji", .string,
          "The emoji, required for `emoji` and `-emoji` and ignored otherwise. macOS 15 and "
            + "newer."),
        Property("partIndex", .integer, "Which part of the target message. Defaults to 0."),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("selectedMessageGuid", .string("4D50CFE4-87A5-49D6-9687-4A5D6C94A29B")),
        ("reaction", .string("emoji")),
        ("emoji", .string("🔥")),
      ])),

    // MARK: Send Later

    .messageSendLater: Body(
      summary: "Schedules a message with Apple, so it sends whether or not this Mac is awake.",
      properties: [
        chatGUID(),
        Property("message", .string, "The text to send.", required: true),
        Property(
          "scheduledFor", .integer,
          "When to deliver it, in epoch MILLISECONDS. Must be in the future.", required: true),
        Property("tempGuid", .string, "Echoed back on the sent message."),
        Property("subject", .string, "Subject line."),
        Property("effectId", .string, "A send effect."),
        Property("selectedMessageGuid", .string, "The message this one replies to."),
        Property("partIndex", .integer, "Which part of the replied-to message."),
        textFormatting,
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("message", .string("Happy birthday!")),
        ("scheduledFor", .int(1_788_440_082_220)),
      ])),

    .messageReschedule: Body(
      summary: "Changes a pending message's text, its delivery time, or both.",
      properties: [
        chatGUID("The conversation the scheduled message is in."),
        Property("message", .string, "Replacement text. Leaves the time alone if sent alone."),
        Property(
          "scheduledFor", .integer,
          "A new delivery time, epoch MILLISECONDS. Leaves the text alone if sent alone."),
        Property("partIndex", .integer, "Which part to rewrite. Defaults to 0."),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("message", .string("Actually, happy anniversary!")),
        ("scheduledFor", .int(1_788_443_682_220)),
      ])),

    .messageSendScheduledNow: Body(
      summary: "Delivers a pending message immediately.",
      properties: [chatGUID("The conversation the scheduled message is in.")],
      example: .obj([("chatGuid", .string("iMessage;-;+15551234567"))])),

    .messageCancelScheduled: Body(
      summary: "Cancels a pending message. Its row is deleted, not marked cancelled.",
      properties: [chatGUID("The conversation the scheduled message is in.")],
      example: .obj([("chatGuid", .string("iMessage;-;+15551234567"))])),

    // MARK: Polls

    .messageCreatePoll: Body(
      summary: "Sends a new poll. macOS 26 and newer.",
      properties: [
        chatGUID(),
        Property(
          "options", .array(of: .string),
          "The choices, in order. At least two, none empty.", required: true),
        Property(
          "title", .string,
          "Accepted and sent, but Messages 26 neither shows a poll title nor keeps one — its "
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
        Property("text", .string, "The choice to add.", required: true),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")), ("text", .string("Thai")),
      ])),

    // MARK: iMessage app balloons

    .messageSendApp: Body(
      summary:
        "Sends an iMessage app's balloon. Supply the payload in whichever shape fits. The "
        + "Polls balloon is REFUSED here — this route writes a template layout and a poll "
        + "needs a live layout, so it would arrive with no options; use POST message/poll.",
      properties: [
        chatGUID(),
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
          "The payload URL verbatim, for an app whose format is neither of the above — an "
            + "https link, or a `data:` URL with a media type."),
        Property(
          "sessionId", .string,
          "The `MSSession` UUID. Omit to start a new one; pass the session of the message "
            + "being answered to continue a conversation."),
        Property("appName", .string, "The app's display name, shown on the balloon."),
        Property("appId", .integer, "The app's App Store id."),
        Property("caption", .string, "The line shown where the balloon cannot be drawn."),
        Property("summary", .string, "The message's fallback summary text."),
      ],
      // A THIRD-PARTY app, deliberately. The obvious example to reach for is Polls, and
      // Polls is the one balloon this route refuses — an example the server would reject
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
            .obj([("name", .string("restaurant")), ("value", .string("12345"))]),
            .obj([("name", .string("time")), ("value", .string("19:00"))]),
          ])
        ),
      ])),

    .messageSendGamePigeon: Body(
      summary: "Sends a Game Pigeon message, doing its payload scramble for you.",
      properties: [
        chatGUID(),
        appPayloadFields,
        Property(
          "version", .integer,
          "Game Pigeon's own payload version. Echo back the one you received; defaults to 52."),
        Property(
          "sessionId", .string,
          "The `MSSession` UUID of the game being continued. Omit only for a new invite."),
        Property("caption", .string, "The line shown on the balloon, e.g. `Your move.`"),
        Property(
          "teamId", .string,
          "The developer team id in the balloon bundle id. Defaults to Game Pigeon's own."),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("version", .int(50)),
        ("sessionId", .string("2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22")),
        ("caption", .string("Your move.")),
        (
          "fields",
          .array([
            .obj([("name", .string("game")), ("value", .string("pool"))]),
            .obj([("name", .string("id")), ("value", .string("2ENROYU7St5CF6e8"))]),
            .obj([("name", .string("player")), ("value", .string("1"))]),
          ])
        ),
      ])),

    // MARK: Conversation state
    //
    // Small bodies, but every field here changes what the request DOES — a spam report
    // that reaches a carrier cannot be withdrawn — so none of them should be discovered
    // by trial and error.

    .chatUnmute: Body(
      summary: "Unmutes a conversation and answers with the resulting state.",
      properties: [
        Property(
          "syncToPairedDevice", .boolean,
          "Push the change to the user's other devices. Defaults to true, which is what "
            + "Messages' own toggle does.")
      ],
      example: .obj([("syncToPairedDevice", .bool(true))]),
      required: false),

    .chatMarkKnown: Body(
      summary: "Accepts a sender, moving the conversation out of Unknown Senders.",
      properties: [
        Property(
          "saveInContacts", .boolean,
          "Also write the sender to the address book. Defaults to FALSE — accepting a "
            + "sender is not the same as editing the user's contacts.")
      ],
      example: .obj([("saveInContacts", .bool(false))]),
      required: false),

    .chatMarkSpam: Body(
      summary: "Marks a conversation as spam.",
      properties: [
        Property(
          "reportToCarrier", .boolean,
          "Also report it to the carrier. Defaults to FALSE, and think before setting it: "
            + "the report is an SMS sent from the user's own number and cannot be undone."),
        Property(
          "dryRun", .boolean,
          "Answer with what would happen and change nothing. Defaults to false."),
      ],
      example: .obj([("reportToCarrier", .bool(false)), ("dryRun", .bool(true))]),
      required: false),

    .chatReportJunk: Body(
      summary: "Reports a conversation as junk, which also deletes it locally.",
      properties: [
        Property(
          "reportToCarrier", .boolean,
          "Also report it to the carrier. Defaults to FALSE, and the report is an SMS from "
            + "the user's own number that cannot be withdrawn."),
        Property(
          "dryRun", .boolean,
          "Answer with what would happen and change nothing. Defaults to false."),
      ],
      example: .obj([("reportToCarrier", .bool(false)), ("dryRun", .bool(true))]),
      required: false),

    // MARK: FaceTime

    .facetimeCall: Body(
      summary: "Places a FaceTime call and hands back a join link for it.",
      properties: [
        Property(
          "addresses", .array(of: .string),
          "Everyone to ring. Use this for a group call.", required: true),
        Property("address", .string, "A single callee, accepted in place of `addresses`."),
        Property(
          "video", .boolean,
          "Ring as FaceTime Video. Defaults to true; false rings as FaceTime Audio."),
      ],
      example: .obj([
        ("addresses", .array([.string("+15551234567")])), ("video", .bool(true)),
      ])),

    .facetimeGenerateLink: Body(
      summary: "Mints a FaceTime link that anyone holding it can join.",
      properties: [
        Property(
          "addresses", .array(of: .string),
          "People to pre-invite onto the link. The link is created either way.")
      ],
      example: .obj([("addresses", .array([.string("+15551234567")]))]),
      required: false),

    .facetimeInvalidateLinks: Body(
      summary: "Invalidates links this server minted.",
      properties: [
        Property(
          "urls", .array(of: .string),
          "The links to invalidate. Omit the field entirely to invalidate all of them.")
      ],
      example: .obj([("urls", .array([.string("https://facetime.apple.com/join#v=1&p=…")]))]),
      required: false),

    .facetimeAdmit: Body(
      summary: "Admits someone knocking at a call. The call is `:group_uuid` in the path.",
      properties: [
        Property(
          "address", .string, "The knocker's handle, as reported by the members route.",
          required: true)
      ],
      example: .obj([("address", .string("+15551234567"))])),

    .facetimeLeaveCall: Body(
      summary: "Hangs up this Mac's side of a call.",
      properties: [
        Property("callUUID", .string, "The call to leave.", required: true),
        Property(
          "call_uuid", .string,
          "The same thing under the name the reference server's clients send. Either is "
            + "accepted; send one."),
      ],
      example: .obj([("callUUID", .string("9E3C0B77-1A44-4D2E-8F51-7C2B9D6E0A13"))])),

    // MARK: Enrollment

    .authRevoke: Body(
      summary: "Revokes a device's token, so its client has to enrol again.",
      properties: [
        Property(
          "device_id", .string, "The device to revoke, as returned by enrollment.", required: true)
      ],
      example: .obj([("device_id", .string("F2A7C1D0-93B4-4E6A-8C15-0D7E2B9A4F38"))])),
  ]

  /// Write routes that take NO body, and why.
  ///
  /// Declared rather than left out, because "this route has no documented input" and "nobody
  /// has documented this route" look identical in the emitted file. Every v2 write route has
  /// to appear in one table or the other; `RequestBodyTests` fails the build otherwise.
  public static let bodyless: [HandlerID: String] = [
    .chatPin: "The conversation is the path; pinning takes no options.",
    .chatUnpin: "The conversation is the path; unpinning takes no options.",
    .chatFetchBackground: "The conversation is the path. `?wait=` is a query parameter.",
    .facetimeCleanup: "Means `clear everything this server minted, now`.",
    .facetimeRestart: "Restarts FaceTime.app. Nothing to configure.",
    .facetimeDismissAlert: "Dismisses whatever alert FaceTime.app is showing.",
    .facetimeHandoff: "The call is `:call_uuid` in the path.",
    .securityClearBlocked: "Clears the whole blocklist. That is the entire request.",
    .securityUnblock: "The entry is `:id` in the path.",
    .securityDisallow: "The entry is `:id` in the path.",
  ]

  /// The declaration as an OpenAPI schema.
  public static func schema(for body: Body) -> OrderedJSON {
    .obj([
      ("type", .string("object")),
      ("description", .string(body.summary)),
      (
        "properties",
        .object(body.properties.map { ($0.name, schema(for: $0.schema, $0.description)) })
      ),
      (
        "required",
        body.properties.contains(where: \.isRequired)
          ? .array(body.properties.filter(\.isRequired).map { .string($0.name) }) : nil
      ),
    ])
  }

  private static func schema(for schema: Schema, _ description: String) -> OrderedJSON {
    switch schema {
    case .array(let element):
      return .obj([
        ("type", .string("array")),
        ("description", .string(description)),
        ("items", self.schema(for: element, "")),
      ])
    case .object(let properties):
      return .obj([
        ("type", .string("object")),
        ("description", description.isEmpty ? nil : .string(description)),
        (
          "properties",
          .object(properties.map { ($0.name, self.schema(for: $0.schema, $0.description)) })
        ),
        (
          "required",
          properties.contains(where: \.isRequired)
            ? .array(properties.filter(\.isRequired).map { .string($0.name) }) : nil
        ),
      ])
    default:
      return .obj([
        ("type", schema.typeName.map(OrderedJSON.string)),
        ("description", description.isEmpty ? nil : .string(description)),
      ])
    }
  }
}
