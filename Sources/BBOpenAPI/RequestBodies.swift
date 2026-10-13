//  RequestBodies
//  JSON request bodies the document describes in full, written by hand.
//
//  Every other schema in the document is INFERRED from recorded fixtures, which is the right
//  default for a SHAPE: a schema derived from a real payload cannot describe a field the
//  server does not actually accept. It is no use at all for the other half of the question.
//  An inferred body names the fields one recording happened to carry, types them, and says
//  nothing about what any of them mean, which value to send, or which of them decide what
//  comes back — and it carries no example, because a recording is not one. A client author
//  reading `{"category": "integer"}` knows the field exists and still cannot use the route.
//
//  So every write route the server has is declared here, with a description per field and a
//  sample a reader can copy. Three rules keep them honest, all enforced by `RequestBodyTests`:
//
//  1. A declaration WINS over an inferred body, because it is the more complete description:
//     but for a route that does have a fixture it must be a SUPERSET of what was inferred.
//     That makes a declaration able to add a field the reference never had, and unable to
//     quietly drop one that was really recorded.
//  2. Every property carries a description, and every body carries an `example`. The example
//     is the point of the exercise: it is what a client author copies.
//  3. A route that takes NO body says so, in `bodyless` below, and the reason is emitted into
//     the operation's description. "This route has no input" and "nobody documented this
//     route" are indistinguishable otherwise, and the difference is what the reader came for.
//
//  `MultipartBodies` declares the file uploads under the same rules, for the same reason.
//
//  See `docs/api/README.md` § Request bodies.

import BBHTTPAPI

public enum RequestBodies {

  /// A property's shape. Deliberately small: these are request bodies, not a type system.
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

  /// One named sample, for a body whose useful requests are not all the same shape.
  ///
  /// Most routes here take one kind of request and one example says everything: a send is a
  /// send. `POST /message/query` is the counter-case, because its `where` is an allowlist of
  /// eight statements serving four unrelated jobs — an incremental sync, a search, a
  /// notification hydration, a page of one conversation — and a single example can only show
  /// one of them. Naming each one is what lets the other three be documented at all rather
  /// than described in prose above an example that does something else.
  public struct Example: Sendable {
    /// The key in the OpenAPI `examples` map. Kebab-case.
    public let name: String
    /// The picker's LABEL, so it is short enough to be one: what this request asks for.
    ///
    /// A viewer renders this collapsed, on one line, in a box it shares with a button, and
    /// truncates what does not fit — measured at 335px against 480px of text, which cut the
    /// search sample off after "with reactio…". A label a reader cannot finish is half the
    /// reason a picker is hard to find at all, so the reasoning goes in `description` and
    /// this stays under `maximumSummaryLength`.
    public let summary: String
    /// Why a client sends this one, for a reader of the document rather than of the picker.
    ///
    /// Scalar renders the summary and NOTHING else: measured against the bundled 1.67.0 by
    /// opening the picker and selecting through it, the collapsed label and each row carry
    /// the summary alone. This is here because the reasoning had to go somewhere when the
    /// summary became a label, and because the emitted file is read by more than one viewer.
    /// Do not move anything a Scalar reader must see into it.
    public let description: String?
    public let value: OrderedJSON

    /// The longest a summary may be. Measured, not chosen: see `summary`.
    public static let maximumSummaryLength = 48

    public init(
      _ name: String, _ summary: String, _ description: String? = nil, _ value: OrderedJSON
    ) {
      self.name = name
      self.summary = summary
      self.description = description
      self.value = value
    }
  }

  public struct Body: Sendable {
    public let summary: String
    public let properties: [Property]
    /// What a caller can copy and send. Never empty.
    ///
    /// A single entry is rendered as the media type's `example`, several as its `examples`
    /// map: the two are mutually exclusive in OpenAPI, and emitting `example` for the common
    /// case keeps every other route's output unchanged.
    public let examples: [Example]
    /// False where every field is optional, so the route works with no body at all.
    public let isRequired: Bool
    /// True where the body is an ARRAY of the object `properties` describes.
    ///
    /// The three contact write routes are batch routes and their bodies are arrays:
    /// `ContactHandlers.entries(in:)` reads the top level as a list and wraps a bare object
    /// into a one-element one. Documenting them as objects would be a declaration that WINS
    /// over the recorded array schema and describes a body no client sends, which is the one
    /// way this table can be worse than no table at all.
    public let isBatch: Bool

    /// The first sample, which is the one a reader meets first.
    public var example: OrderedJSON { examples[0].value }

    public init(
      summary: String, properties: [Property], example: OrderedJSON, required: Bool = true,
      batch: Bool = false
    ) {
      self.init(
        summary: summary, properties: properties,
        examples: [Example("default", summary, nil, example)], required: required, batch: batch)
    }

    public init(
      summary: String, properties: [Property], examples: [Example], required: Bool = true,
      batch: Bool = false
    ) {
      self.summary = summary
      self.properties = properties
      self.examples = examples
      self.isRequired = required
      self.isBatch = batch
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

    // The route the whole `where` allowlist exists for, and the one whose fixture is least
    // like a real request: the recording sends `limit`, `offset`, `sort` and `with`, so the
    // document described a page of the newest messages and not one of the four jobs clients
    // actually use this for. `where` in particular cannot be discovered — it is eight
    // statements matched on shape, and anything else is a 400 — so a client author reading
    // only the inferred body would have had to find them in `MessageFilter`.
    .messageQuery: Body(
      summary:
        "Pages the message table. Every field is optional: an empty body answers with the "
        + "newest 100 messages across every conversation. `metadata` carries `total` (rows "
        + "matching every filter, not the size of the table), `count` (rows on this page), "
        + "`limit` and `offset`.",
      properties: [
        Property(
          "chatGuid", .string,
          "Scope the page to one conversation. A GUID that names no chat answers 200 with an "
            + "empty `data` and a message naming it, which is how a client tells \"no such "
            + "chat\" from \"no messages matching\"."),
        Property(
          "with", .array(of: .string),
          "Relations to load. Matched as substrings, so `chat`, `chats` and "
            + "`chat.participants` all select the chat relation: `chat`, "
            + "`chat.participants`, `attachment`, `attachment.metadata`, `attributedBody`, "
            + "`messageSummaryInfo`, `payloadData`. The sending handle is always loaded and "
            + "needs no entry. Ask for `attributedBody` if you render text: an outgoing "
            + "message's `text` column is null on Ventura and newer and its words are in "
            + "there. `attachment.metadata` opens each file off disk, so it costs a probe "
            + "per attachment and is off unless asked for."),
        Property(
          "where",
          .array(
            of: .object(properties: [
              Property(
                "statement", .string,
                "One of the statements listed above. Matched on shape, so spacing and the "
                  + "placeholder's name are yours: `message.ROWID>:since` is the same "
                  + "filter as `message.ROWID > :startRowId`.", required: true),
              Property(
                "args", .anything,
                "The bound values, keyed by placeholder name without its colon. An empty "
                  + "object for a statement that binds nothing.", required: true),
            ])),
          "Filters, ANDed together, and applied to `metadata.total` as well as to the page. "
            + "Each entry is one statement from a fixed set; a statement outside it is "
            + "refused with a 400 quoting it back, never ignored. The set: "
            + "`message.ROWID > :x`, `message.ROWID <= :x`, "
            + "`message.is_from_me = :x` (0 or 1), "
            + "`message.text LIKE :x COLLATE NOCASE` (write your own `%` wildcards), "
            + "`message.guid IN (:...x)`, `message.associated_message_guid IS NULL`, "
            + "`chat.guid = :x`, `handle.id = :x`."),
        Property(
          "limit", .integer, "Page size, 1 to 1000 inclusive. Defaults to 100."),
        Property("offset", .integer, "Rows to skip before the page. Defaults to 0."),
        Property(
          "sort", .string,
          "`DESC` for newest first, which is the default, or `ASC` for oldest first. Page a "
            + "sync with `ASC` so a message arriving mid-sync cannot shift a page you have "
            + "already read."),
        Property(
          "after", .integer,
          "Only messages sent at or after this time, epoch MILLISECONDS. Inclusive."),
        Property(
          "before", .integer,
          "Only messages sent at or before this time, epoch MILLISECONDS. Inclusive."),
        Property(
          "convertAttachments", .boolean,
          "Accepted and carried, but no field of this response depends on it: an attachment "
            + "is converted when it is downloaded, not when a message is serialized. "
            + "Defaults to true."),
      ],
      examples: [
        Example(
          "recent-in-chat",
          "The newest page of one conversation.",
          "The relations a transcript needs, in one request. `attributedBody` is in the list "
            + "because an outgoing message's `text` column is null on Ventura and newer.",
          .obj([
            ("chatGuid", .string("iMessage;-;+15551234567")),
            (
              "with",
              .array([
                .string("chat"), .string("chat.participants"), .string("attachment"),
                .string("attributedBody"), .string("messageSummaryInfo"),
              ])
            ),
            ("limit", .int(25)),
            ("sort", .string("DESC")),
          ])),
        Example(
          "incremental-sync",
          "One page of a fixed ROWID window.",
          "How a client catches up without re-reading what it already has. The top of the "
            + "window is pinned with `<=` so messages arriving mid-sync cannot shift the "
            + "pages under it; page until `metadata.count` is zero.",
          .obj([
            (
              "where",
              .array([
                .obj([
                  ("statement", .string("message.ROWID > :startRowId")),
                  ("args", .obj([("startRowId", .int(418_002))])),
                ]),
                // The top of the window is PINNED, so messages arriving mid-sync cannot
                // shift the pages under a client that is still reading them.
                .obj([
                  ("statement", .string("message.ROWID <= :endRowId")),
                  ("args", .obj([("endRowId", .int(420_679))])),
                ]),
              ])
            ),
            ("with", .array([.string("chat"), .string("attachment")])),
            ("sort", .string("ASC")),
            ("limit", .int(1000)),
            ("offset", .int(0)),
          ])),
        Example(
          "search-one-chat",
          "A text search inside one conversation.",
          "Reactions and replies are excluded by `associated_message_guid IS NULL`, which is "
            + "what keeps a search result list from filling with tapbacks.",
          .obj([
            (
              "where",
              .array([
                .obj([
                  ("statement", .string("message.text LIKE :term COLLATE NOCASE")),
                  ("args", .obj([("term", .string("%dinner%"))])),
                ]),
                .obj([
                  ("statement", .string("message.associated_message_guid IS NULL")),
                  ("args", .obj([])),
                ]),
                .obj([
                  ("statement", .string("chat.guid = :guid")),
                  ("args", .obj([("guid", .string("iMessage;-;+15551234567"))])),
                ]),
              ])
            ),
            ("with", .array([.string("chat"), .string("attributedBody")])),
            ("limit", .int(50)),
          ])),
        Example(
          "sent-by-me-to-one-handle",
          "This account's messages to one handle.",
          "Scoped to a time window as well. `after` and `before` are epoch milliseconds and "
            + "both bounds are inclusive.",
          .obj([
            (
              "where",
              .array([
                .obj([
                  ("statement", .string("message.is_from_me = :fromMe")),
                  ("args", .obj([("fromMe", .int(1))])),
                ]),
                .obj([
                  ("statement", .string("handle.id = :address")),
                  ("args", .obj([("address", .string("+15551234567"))])),
                ]),
              ])
            ),
            ("after", .int(1_788_400_000_000)),
            ("before", .int(1_788_486_400_000)),
            ("sort", .string("ASC")),
          ])),
        Example(
          "hydrate-by-guid",
          "The messages behind a set of GUIDs.",
          "How a client fills in a push notification: the payload carries GUIDs, and this "
            + "turns them into rows without a second request per message.",
          .obj([
            (
              "where",
              .array([
                .obj([
                  ("statement", .string("message.guid IN (:...guids)")),
                  (
                    "args",
                    .obj([
                      (
                        "guids",
                        .array([
                          .string("4D50CFE4-87A5-49D6-9687-4A5D6C94A29B"),
                          .string("B1F0A7C2-5E3D-4A19-9C48-7D2E6B0F3A51"),
                        ])
                      )
                    ])
                  ),
                ])
              ])
            ),
            ("with", .array([.string("chat"), .string("attachment")])),
          ])),
      ],
      required: false),

    .messageSendText: Body(
      summary: "Sends a text message.",
      properties: [
        chatGUID(),
        Property("message", .string, "The text to send.", required: true),
        // Neither is required unconditionally, which is all `required` can say: the
        // validator demands `tempGuid` only for an AppleScript send. See `ValidationRules`.
        Property(
          "tempGuid", .string,
          "Client-generated id echoed back on the sent message, so a client can match the "
            + "response to the row it inserted optimistically. Required for AppleScript."),
        Property(
          "method", .string,
          "`apple-script` or `private-api`. AppleScript needs no helper; the Private API is "
            + "required for subjects, effects, replies and formatting."),
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
        Property(
          "ddScan", .boolean,
          "Scan the text for links before it is scheduled, as on `message/text`."),
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
        + "Polls balloon is REFUSED here: this route writes a template layout and a poll "
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
          "The payload URL verbatim, for an app whose format is neither of the above; an "
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
        appPayloadFields,
        Property(
          "version", .integer,
          "Game Pigeon's own payload version, the `ver=` on the payload URL. Echo back the "
            + "one you received; defaults to 52. Genuine invites carry 45 through 50 "
            + "depending on the game and how old the sending app is."),
        Property(
          "sessionId", .string,
          "The `MSSession` UUID of the game being continued. Omit only for a new invite."),
        Property("caption", .string, "The line shown on the balloon, e.g. `Your move.`"),
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

    // MARK: Conversation state
    //
    // Small bodies, but every field here changes what the request DOES (a spam report
    // that reaches a carrier cannot be withdrawn) so none of them should be discovered
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
          "Also write the sender to the address book. Defaults to FALSE: accepting a "
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

    // MARK: The paged read routes
    //
    // POST rather than GET because the reference made them POST, so their inputs are bodies
    // and a client author has nowhere to look for them but here. The recorded fixtures cover
    // the paging fields and none of the filters, which is the half that decides what comes
    // back.

    .chatQuery: Body(
      summary:
        "Pages the conversation list. Every field is optional: an empty body answers with the "
        + "first 1000 chats. `metadata` carries `total` (chats matching the filter, not the "
        + "size of the table), `count`, `limit` and `offset`.",
      properties: [
        Property(
          "with", .array(of: .string),
          "Relations to load. `lastmessage` (or `last-message`) is the only one this route "
            + "reads: participants are ALWAYS loaded here, which is the opposite of "
            + "`GET /chat/{guid}`, where they are loaded only when asked for. A client that "
            + "reads an empty participant list as \"this chat is not real\" is the reason "
            + "that asymmetry is worth knowing."),
        Property(
          "guid", .string,
          "Scope the page to one conversation. `metadata.total` then counts what the filter "
            + "matched rather than the whole table."),
        Property("limit", .integer, "Page size, 1 to 1000 inclusive. Defaults to 1000."),
        Property("offset", .integer, "Chats to skip before the page. Defaults to 0."),
        Property(
          "sort", .string,
          "`lastmessage`, the only accepted value, orders by the most recent message. Asking "
            + "for the `lastmessage` relation and giving no sort selects it anyway, so the "
            + "two halves of a conversation list cannot disagree about the order."),
        Property(
          "includeArchived", .boolean,
          "Defaults to true. Send false to leave archived conversations out of both the page "
            + "and the total."),
      ],
      examples: [
        Example(
          "conversation-list",
          "A page of the conversation list.",
          "What a client builds its chat list from: the newest message on each conversation, "
            + "ordered by it. Page with `offset` until `metadata.count` is zero.",
          .obj([
            ("with", .array([.string("lastmessage")])),
            ("sort", .string("lastmessage")),
            ("limit", .int(100)),
            ("offset", .int(0)),
          ])),
        Example(
          "one-conversation",
          "One conversation, by its GUID.",
          "Scoped with `guid` rather than read through `GET /chat/{guid}`, because this route "
            + "loads participants without being asked and that one does not.",
          .obj([
            ("guid", .string("iMessage;-;+15551234567")),
            ("with", .array([.string("lastmessage")])),
          ])),
      ],
      required: false),

    .handleQuery: Body(
      summary:
        "Pages the handle table: the addresses this Mac has messaged or been messaged by. "
        + "Every field is optional. `metadata` carries `total` (handles matching `address`, "
        + "not the size of the table), `count`, `limit` and `offset`.",
      properties: [
        Property(
          "address", .string,
          "One address to look up, matched exactly. Applied to `metadata.total` as well as "
            + "to the page, so a client asking about one correspondent is not handed an "
            + "unfiltered page of a thousand."),
        Property(
          "with", .array(of: .string),
          "Relations to load. Any entry containing `chat` loads the conversations the handle "
            + "is in, so `chat`, `chats` and `chat.participants` all select it."),
        Property("limit", .integer, "Page size, 1 to 1000 inclusive. Defaults to 1000."),
        Property("offset", .integer, "Handles to skip before the page. Defaults to 0."),
      ],
      example: .obj([
        ("address", .string("+15551234567")),
        ("with", .array([.string("chat")])),
        ("limit", .int(100)),
        ("offset", .int(0)),
      ]),
      required: false),

    .contactQuery: Body(
      summary:
        "Looks up contacts by address, or pages the whole address book when `addresses` is "
        + "empty. Answers with the matching contacts and nothing else: there is no envelope "
        + "metadata on this route.",
      properties: [
        Property(
          "addresses", .array(of: .string),
          "Phone numbers or email addresses to resolve, normalised before matching. An empty "
            + "array or an absent field lists everything; a value that is not an array is "
            + "refused rather than read as empty, because an unfiltered page is not what a "
            + "client asking about one address wanted."),
        Property(
          "extraProperties", .array(of: .string),
          "Properties that cost extra work and are off by default. `avatar` is the one that "
            + "exists, and it base64-encodes each contact's photo into the response. A "
            + "comma-separated string is accepted in place of the array."),
        Property("limit", .integer, "Page size when listing. Defaults to 1000."),
        Property("offset", .integer, "Contacts to skip when listing. Defaults to 0."),
      ],
      examples: [
        Example(
          "resolve-addresses",
          "Names for the addresses in a chat.",
          "The request a client makes once per conversation it opens: hand it the "
            + "participants and it answers with whatever the address book knows about them.",
          .obj([
            (
              "addresses",
              .array([.string("+15551234567"), .string("someone@example.com")])
            )
          ])),
        Example(
          "whole-book-with-avatars",
          "A page of the address book, with photos.",
          "`avatar` is opt-in because it base64-encodes an image per contact; ask for it on "
            + "the page a client is about to display, not on a background sync.",
          .obj([
            ("addresses", .array([])),
            ("extraProperties", .array([.string("avatar")])),
            ("limit", .int(200)),
            ("offset", .int(0)),
          ])),
      ],
      required: false),

    // MARK: Conversation administration

    .chatCreate: Body(
      summary:
        "Creates a conversation and answers with the whole chat: its participants, and the "
        + "message the create sent. What is possible depends on the configuration — the "
        + "Private API creates either kind and needs no first message; without it a "
        + "ONE-TO-ONE chat is created by sending `message` through AppleScript, and a GROUP "
        + "needs the user-installed Shortcut.",
      properties: [
        Property(
          "addresses", .array(of: .string),
          "Who the conversation is with. One address makes a one-to-one chat, two or more a "
            + "group.", required: true),
        Property(
          "message", .string,
          "The first message. Optional with the Private API, REQUIRED without it: there is "
            + "no other way to bring a chat into existence, so a create with no message is "
            + "refused with that as the reason."),
        Property(
          "service", .string, "`iMessage` or `SMS`. Defaults to `iMessage`."),
        Property(
          "method", .string,
          "`apple-script` or `private-api`. Accepted, and NOT acted on: this server chooses "
            + "the backend from what it has, so naming one cannot force it. Documented "
            + "because clients send it and the reference validates it."),
        Property(
          "tempGuid", .string,
          "Client-generated id echoed back on the message the create sent, so a client can "
            + "match it to the row it inserted optimistically."),
      ],
      examples: [
        Example(
          "one-to-one",
          "A new chat with one person.",
          "Works on every configuration. Without the Private API the chat comes into "
            + "existence as a side effect of sending `message`, which is why it is here.",
          .obj([
            ("addresses", .array([.string("+15551234567")])),
            ("service", .string("iMessage")),
            ("message", .string("Hey!")),
            ("tempGuid", .string("6E2C1A2B-0F2E-4E77-9B6C-2E5A3D9F1A44")),
          ])),
        Example(
          "group",
          "A new group chat.",
          "Needs the Private API or the installed Shortcut. A server with neither refuses "
            + "this and names the setting that fixes it rather than failing generically.",
          .obj([
            (
              "addresses",
              .array([
                .string("+15551234567"), .string("+15557654321"),
                .string("someone@example.com"),
              ])
            ),
            ("service", .string("iMessage")),
            ("message", .string("Making a group for the weekend")),
          ])),
      ]),

    .chatUpdate: Body(
      summary:
        "Renames a GROUP conversation. A body with no `displayName` answers 200 and changes "
        + "nothing, as the reference does; renaming a one-to-one chat is refused, because "
        + "Messages accepts that request, reports success and does nothing.",
      properties: [
        Property(
          "displayName", .string,
          "The new group name, at least one character. An empty string is a 400: omit the "
            + "field to change nothing, rather than sending one.")
      ],
      example: .obj([("displayName", .string("Weekend plans"))]),
      required: false),

    .chatAddParticipant: Body(
      summary:
        "Adds someone to a group conversation. Two routes share this: `POST :guid/participant` "
        + "is the older spelling and `POST :guid/participant/add` the newer, and both ship.",
      properties: [
        Property(
          "address", .string,
          "The phone number or email address to add. Accepted as a query parameter too, "
            + "which is what makes the DELETE spelling of the removal route usable.",
          required: true)
      ],
      example: .obj([("address", .string("+15551234567"))])),

    .chatRemoveParticipant: Body(
      summary:
        "Removes someone from a group conversation. Two routes share this: "
        + "`DELETE :guid/participant` is the older spelling and "
        + "`POST :guid/participant/remove` the newer, and both ship.",
      properties: [
        Property(
          "address", .string,
          "The participant to remove, as it appears in the chat's `participants`. Accepted "
            + "as a query parameter too, for clients whose HTTP layer will not put a body on "
            + "a DELETE.", required: true)
      ],
      example: .obj([("address", .string("+15551234567"))])),

    // MARK: Message writes
    //
    // `parts` on the multipart route is the field with no discoverable shape: mentions,
    // inline attachments and per-run formatting all arrive through it, in order.

    .messageSendMultipart: Body(
      summary:
        "Sends one message assembled from ORDERED parts: text runs, mentions and attachments "
        + "in a single balloon. Private API only. The parts are applied in the order they "
        + "arrive, and a part carrying neither `text` nor `filePath` is refused rather than "
        + "skipped, because dropping one would renumber every part after it.",
      properties: [
        chatGUID(),
        Property(
          "parts",
          .array(
            of: .object(properties: [
              Property(
                "text", .string,
                "This part's text. A part needs `text` or `filePath`."),
              Property(
                "mention", .string,
                "The address this run mentions, which is what turns it into a mention rather "
                  + "than into text that looks like one. `text` is the name the recipient "
                  + "sees; this is who it resolves to."),
              Property(
                "filePath", .string,
                "A file already on this Mac, staged by `POST attachment/upload`, to send as "
                  + "this part: the `<uuid>/<file>` path that route answered with. "
                  + "`attachment` (the v1 name) and `attachmentPath` are accepted as well. "
                  + "Paths are confined to the upload store, so an arbitrary path on the Mac "
                  + "is refused."),
              Property(
                "name", .string,
                "The filename the recipient sees for this part's file. Outranks the name it "
                  + "was uploaded under; without it, that name is kept."),
              textFormatting,
              Property(
                "partIndex", .integer,
                "Sent by the app and not read: position in the array is the index. "
                  + "Documented because clients send it, not because it does anything."),
            ])),
          "The message, in order. One entry per run of text, mention or attachment.",
          required: true),
        Property(
          "tempGuid", .string,
          "Client-generated id echoed back on the sent message. Also the deduplication key: "
            + "a second send under a `tempGuid` still in flight is refused rather than sent "
            + "twice."),
        Property("subject", .string, "Subject line."),
        Property("effectId", .string, "A send effect, applied to the whole message."),
        Property(
          "selectedMessageGuid", .string, "The message this one replies to, threading it."),
        Property("partIndex", .integer, "Which part of the replied-to message. Defaults to 0."),
        Property(
          "ddScan", .boolean,
          "Scan the text for links and data detectors. The app sends it only to a server "
            + "older than macOS 14, and only when the text contains a URL."),
      ],
      examples: [
        Example(
          "mention-in-a-group",
          "A message that mentions someone.",
          "Three runs, and only the middle one carries `mention`. The mention is a property "
            + "of the run, so the name a recipient reads and the address it resolves to are "
            + "set in the same place.",
          .obj([
            ("chatGuid", .string("iMessage;+;chat000000000000000001")),
            ("tempGuid", .string("6E2C1A2B-0F2E-4E77-9B6C-2E5A3D9F1A44")),
            (
              "parts",
              .array([
                .obj([("text", .string("Morning "))]),
                .obj([
                  ("text", .string("Sam")), ("mention", .string("+15551234567")),
                ]),
                .obj([("text", .string(", are we still on for 7?"))]),
              ])
            ),
          ])),
        Example(
          "text-and-a-photo",
          "Text and an attachment in one balloon.",
          "The file is staged first with `POST attachment/upload`, whose response carries "
            + "the path to put here. Sending it as a part is what keeps it in the same "
            + "balloon as the text instead of arriving as a second message.",
          .obj([
            ("chatGuid", .string("iMessage;-;+15551234567")),
            ("tempGuid", .string("B1F0A7C2-5E3D-4A19-9C48-7D2E6B0F3A51")),
            (
              "parts",
              .array([
                .obj([("text", .string("Here it is"))]),
                .obj([
                  ("filePath", .string("8c7d9e0f-1a2b-3c4d-5e6f-708192a3b4c5/IMG_0001.heic")),
                  ("name", .string("Beach.heic")),
                ]),
              ])
            ),
          ])),
        Example(
          "formatted-reply",
          "A styled reply in a thread.",
          "`selectedMessageGuid` threads the message; `textFormatting` styles a range of one "
            + "part, in UTF-16 code units, so an emoji earlier in the run shifts the offsets.",
          .obj([
            ("chatGuid", .string("iMessage;-;+15551234567")),
            ("tempGuid", .string("4D50CFE4-87A5-49D6-9687-4A5D6C94A29B")),
            ("selectedMessageGuid", .string("F2A7C1D0-93B4-4E6A-8C15-0D7E2B9A4F38")),
            ("partIndex", .int(0)),
            (
              "parts",
              .array([
                .obj([
                  ("text", .string("Booked it")),
                  (
                    "textFormatting",
                    .array([
                      .obj([
                        ("start", .int(0)), ("length", .int(6)),
                        ("styles", .array([.string("bold")])),
                      ])
                    ])
                  ),
                ])
              ])
            ),
          ])),
      ]),

    .messageEdit: Body(
      summary:
        "Rewrites a message this account sent. Private API only, and the message must be "
        + "recent enough that Messages still allows an edit. The path's `:guid` is the "
        + "message; the body is what it becomes.",
      properties: [
        Property("editedMessage", .string, "The replacement text.", required: true),
        Property(
          "backwardsCompatibilityMessage", .string,
          "What a recipient on an OS that cannot render an edit receives in place of it. "
            + "Required, because the reference's validator requires it — and worth writing "
            + "deliberately: this is the sentence half the recipients actually see.",
          required: true),
        Property(
          "partIndex", .integer,
          "Which part of the message to rewrite. Defaults to 0, which is the whole of an "
            + "ordinary text message."),
      ],
      example: .obj([
        ("editedMessage", .string("Dinner at 8, not 7")),
        ("backwardsCompatibilityMessage", .string("Edited to \u{201C}Dinner at 8, not 7\u{201D}")),
        ("partIndex", .int(0)),
      ])),

    .messageUnsend: Body(
      summary:
        "Unsends a message this account sent, which removes it from every device in the "
        + "conversation. Private API only, and subject to the same recency limit Messages "
        + "applies to its own Undo Send.",
      properties: [
        Property(
          "partIndex", .integer,
          "Which part to retract. Defaults to 0, which is the whole of an ordinary text "
            + "message; a multipart message retracts one part at a time.")
      ],
      example: .obj([("partIndex", .int(0))]),
      required: false),

    // MARK: Scheduled messages
    //
    // This server's own scheduler, which holds the message and sends it when the time comes.
    // Not to be confused with Send Later above, which hands the message to Apple.

    .scheduleCreate: Body(
      summary:
        "Schedules a message for this server to send later. The Mac has to be awake and the "
        + "server running when the time comes — hand the message to Apple with "
        + "`POST message/send-later` instead if it has to go out regardless. All four fields "
        + "are required, `schedule` included: a one-off is `{\"type\": \"once\"}`.",
      properties: [
        Property(
          "type", .string,
          "What the entry does. `send-message` is the only kind that exists.", required: true),
        Property(
          "payload",
          .object(properties: [
            Property("chatGuid", .string, "The conversation to send to.", required: true),
            Property("message", .string, "The text to send.", required: true),
            Property(
              "method", .string,
              "`apple-script` or `private-api`, chosen when the message is scheduled rather "
                + "than when it is sent.", required: true),
          ]),
          "What to send when the time comes. All three fields are required, and an empty "
            + "string counts as missing.", required: true),
        Property(
          "scheduledFor", .integer,
          "When to send it, epoch MILLISECONDS. A time in the past is refused rather than "
            + "sent immediately: a client with a wrong clock would otherwise fire off a "
            + "message meant for next week, and there is no recalling it.", required: true),
        Property(
          "schedule",
          .object(properties: [
            Property(
              "type", .string, "`once` or `recurring`.", required: true),
            Property(
              "interval", .integer,
              "How many `intervalType` units between sends. At least 1. Required for "
                + "`recurring`."),
            Property(
              "intervalType", .string,
              "One of `hourly`, `daily`, `weekly`, `monthly`, `yearly`. Required for "
                + "`recurring`, and a value outside that list is refused — a typo used to be "
                + "stored, send once, and go on reporting itself as recurring forever."),
          ]),
          "How often it repeats. Required even for a one-off.", required: true),
      ],
      examples: [
        Example(
          "one-off",
          "One message, at one time.",
          "`schedule` is still required; `{\"type\": \"once\"}` is what a one-off sends, and "
            + "is what the app sends from its conversation view.",
          .obj([
            ("type", .string("send-message")),
            (
              "payload",
              .obj([
                ("chatGuid", .string("iMessage;-;+15551234567")),
                ("message", .string("Happy birthday!")),
                ("method", .string("private-api")),
              ])
            ),
            ("scheduledFor", .int(1_788_440_082_220)),
            ("schedule", .obj([("type", .string("once"))])),
          ])),
        Example(
          "every-week",
          "A message that repeats.",
          "The series counts from `scheduledFor`, and rescheduling moves the whole series to "
            + "the new date rather than keeping it on the original one.",
          .obj([
            ("type", .string("send-message")),
            (
              "payload",
              .obj([
                ("chatGuid", .string("iMessage;+;chat000000000000000001")),
                ("message", .string("Standup in 10")),
                ("method", .string("private-api")),
              ])
            ),
            ("scheduledFor", .int(1_788_440_082_220)),
            (
              "schedule",
              .obj([
                ("type", .string("recurring")), ("interval", .int(1)),
                ("intervalType", .string("weekly")),
              ])
            ),
          ])),
      ]),

    .scheduleUpdate: Body(
      summary:
        "Reschedules a PENDING message. One already sent, or failed, is refused rather than "
        + "silently accepted, because a client showing a future send that will never happen "
        + "is worse than an error. Send the whole entry: the same four fields the create "
        + "takes, with the changes in them.",
      properties: [
        Property(
          "type", .string, "`send-message`, as on the create.", required: true),
        Property(
          "payload",
          .object(properties: [
            Property("chatGuid", .string, "The conversation to send to.", required: true),
            Property("message", .string, "The text to send.", required: true),
            Property("method", .string, "`apple-script` or `private-api`.", required: true),
          ]),
          "The replacement payload, validated exactly as the create's is.", required: true),
        Property(
          "scheduledFor", .integer,
          "The new send time, epoch MILLISECONDS, and it must be in the future. Moving it "
            + "restarts a recurring series from the new date.", required: true),
        Property(
          "schedule",
          .object(properties: [
            Property("type", .string, "`once` or `recurring`.", required: true),
            Property("interval", .integer, "Units between sends. At least 1."),
            Property(
              "intervalType", .string,
              "One of `hourly`, `daily`, `weekly`, `monthly`, `yearly`."),
          ]),
          "The replacement recurrence.", required: true),
      ],
      example: .obj([
        ("type", .string("send-message")),
        (
          "payload",
          .obj([
            ("chatGuid", .string("iMessage;-;+15551234567")),
            ("message", .string("Actually, happy anniversary!")),
            ("method", .string("private-api")),
          ])
        ),
        ("scheduledFor", .int(1_788_443_682_220)),
        ("schedule", .obj([("type", .string("once"))])),
      ])),

    // MARK: Contacts
    //
    // THE THREE WRITE ROUTES TAKE AN ARRAY, and that is the fact a client author most needs:
    // they commit every entry they can and report the rest in `metadata.errors` rather than
    // failing the request, so one malformed contact in a sync of a hundred costs one.

    .contactCreate: Body(
      summary:
        "Creates contacts in the server's own address book — not in the Mac's. A BATCH: send "
        + "an array, and each entry is committed or reported in `metadata.errors` "
        + "independently. A bare object is accepted and treated as a one-entry batch. An "
        + "entry needs at least one of `firstName`, `lastName` or `displayName`, and at "
        + "least one phone number or email address.",
      properties: [
        Property("firstName", .string, "Given name."),
        Property("lastName", .string, "Family name."),
        Property(
          "displayName", .string,
          "The name to show. Sent on its own where a contact has no separable parts, such as "
            + "a business."),
        Property("nickname", .string, "What the user calls this person."),
        Property("birthday", .string, "Stored and handed back verbatim; no format is imposed."),
        Property(
          "phoneNumbers", .array(of: .string),
          "Phone numbers, as strings. An array of `{\"address\": …}` objects is read too, "
            + "which is the shape a contact read back from this API has."),
        Property(
          "emails", .array(of: .string),
          "Email addresses. `emailAddresses` is accepted under the same rules and the two "
            + "are merged, so a client round-tripping a contact does not lose either."),
        Property(
          "externalId", .string,
          "The id this contact has in the client's own store, so a later sync can find it "
            + "again through `GET contact/external/{externalId}`. `externalID` is accepted "
            + "as well."),
      ],
      example: .array([
        .obj([
          ("firstName", .string("Sam")),
          ("lastName", .string("Rivera")),
          ("displayName", .string("Sam Rivera")),
          ("phoneNumbers", .array([.string("+15551234567")])),
          ("emails", .array([.string("someone@example.com")])),
          ("externalId", .string("contacts-store-4182")),
        ]),
        .obj([
          ("displayName", .string("Corner Bakery")),
          ("phoneNumbers", .array([.string("+15557654321")])),
        ]),
      ]),
      batch: true),

    .contactUpdate: Body(
      summary:
        "Replaces contacts the server holds. Two routes share this: `PUT /contact` takes an "
        + "array with an `id` per entry, and `PUT /contact/{id}` takes one entry under the "
        + "path's id. The entry REPLACES the stored contact, so send the whole record rather "
        + "than the fields that changed. An id that names no contact is a 400 quoting it.",
      properties: [
        Property(
          "id", .string,
          "The contact to replace, as returned by a read. Required on `PUT /contact`, where "
            + "there is no path to carry it; ignored on `PUT /contact/{id}`. A numeric id is "
            + "accepted as a number."),
        Property("firstName", .string, "Given name."),
        Property("lastName", .string, "Family name."),
        Property("displayName", .string, "The name to show."),
        Property("nickname", .string, "What the user calls this person."),
        Property("birthday", .string, "Stored and handed back verbatim."),
        Property(
          "phoneNumbers", .array(of: .string),
          "The complete set of phone numbers after the update, not an addition to it."),
        Property(
          "emails", .array(of: .string),
          "The complete set of email addresses after the update. `emailAddresses` is read too."),
        Property("externalId", .string, "The client's own id for this contact."),
      ],
      example: .array([
        .obj([
          ("id", .string("9E3C0B77-1A44-4D2E-8F51-7C2B9D6E0A13")),
          ("firstName", .string("Sam")),
          ("lastName", .string("Rivera")),
          ("displayName", .string("Sam Rivera")),
          ("phoneNumbers", .array([.string("+15551234567"), .string("+15557654321")])),
          ("emails", .array([.string("someone@example.com")])),
        ])
      ]),
      batch: true),

    .contactDelete: Body(
      summary:
        "Deletes contacts from the server's address book. `DELETE /contact` takes an array "
        + "and answers with the ids it removed; `DELETE /contact/{id}` takes no body at all "
        + "and answers with a message. An entry may be a bare id — a string or a number — "
        + "instead of an object.",
      properties: [
        Property(
          "id", .string,
          "The contact to delete. An id that names no contact is reported in "
            + "`metadata.errors` and the rest of the batch still commits.", required: true)
      ],
      example: .array([
        .obj([("id", .string("9E3C0B77-1A44-4D2E-8F51-7C2B9D6E0A13"))]),
        .obj([("id", .string("F2A7C1D0-93B4-4E6A-8C15-0D7E2B9A4F38"))]),
      ]),
      batch: true),

    // MARK: Server administration

    .serverMarkAlertRead: Body(
      summary:
        "Marks server alerts read. An empty list is a 400, not \"mark everything\": the two "
        + "differ by one parse failure, and the wrong one of them is unrecoverable.",
      properties: [
        Property(
          "ids", .array(of: .integer),
          "The alerts to mark, as returned by `GET server/alert`. Numbers and strings are "
            + "both read, because clients send both.", required: true),
        Property(
          "id", .integer,
          "A single alert, accepted alongside `ids` and appended to it."),
      ],
      example: .obj([("ids", .array([.int(6), .int(7)]))])),

    .serverMarkAlertReadV2: Body(
      summary:
        "Marks server alerts read. The same request as the v1 route, on the v2 prefix, so a "
        + "client that started a flow on v2 never has to drop back to finish it.",
      properties: [
        Property(
          "ids", .array(of: .integer),
          "The alerts to mark, as returned by `GET server/alert`. Numbers and strings are "
            + "both read.", required: true),
        Property("id", .integer, "A single alert, appended to `ids`."),
      ],
      example: .obj([("ids", .array([.int(6), .int(7)]))])),

    .backupCreateTheme: Body(
      summary:
        "Stores a named theme for clients to sync. THE WHOLE BODY IS STORED, not just "
        + "`data`: whatever a client puts here is what `GET backup/theme` hands back, so the "
        + "document's shape is the client's to decide. Posting an existing name replaces it.",
      properties: [
        Property(
          "name", .string,
          "What the backup is called, 3 to 50 characters. The key a client reads it back by, "
            + "and the key a replace matches on.", required: true),
        Property(
          "data", .anything,
          "The theme itself, in whatever shape the client uses. Required, and not inspected.",
          required: true),
      ],
      example: .obj([
        ("name", .string("Midnight")),
        (
          "data",
          .obj([
            ("name", .string("Midnight")),
            ("primaryColor", .string("#5B8DEF")),
            ("surfaceColor", .string("#101114")),
          ])
        ),
      ])),

    .backupDeleteTheme: Body(
      summary:
        "Deletes one named theme. The name is REQUIRED: a nameless delete used to remove "
        + "every theme the user had, and the reference has never allowed one.",
      properties: [
        Property(
          "name", .string,
          "The theme to delete, 3 to 50 characters. Accepted as a query parameter too, for "
            + "clients whose HTTP layer will not put a body on a DELETE.", required: true)
      ],
      example: .obj([("name", .string("Midnight"))])),

    .backupCreateSettings: Body(
      summary:
        "Stores a named client settings backup. As with themes, THE WHOLE BODY IS STORED and "
        + "handed back unchanged, so the document is the client's own; posting an existing "
        + "name replaces it.",
      properties: [
        Property(
          "name", .string,
          "What the backup is called, 3 to 50 characters.", required: true),
        Property(
          "data", .anything,
          "The settings themselves, in whatever shape the client uses. Required, and not "
            + "inspected.", required: true),
      ],
      example: .obj([
        ("name", .string("Pixel 9")),
        (
          "data",
          .obj([
            ("name", .string("Pixel 9")),
            ("autoStart", .bool(true)),
            ("sendDelay", .int(0)),
          ])
        ),
      ])),

    .backupDeleteSettings: Body(
      summary:
        "Deletes one named settings backup. The name is REQUIRED, for the same reason the "
        + "theme delete requires one.",
      properties: [
        Property(
          "name", .string,
          "The backup to delete, 3 to 50 characters. Accepted as a query parameter too.",
          required: true)
      ],
      example: .obj([("name", .string("Pixel 9"))])),

    .webhookCreate: Body(
      summary:
        "Registers a URL this server POSTs events to. An event name outside the list is "
        + "REFUSED rather than stored: a typo used to create a webhook that matched nothing, "
        + "fired never, and said so nowhere.",
      properties: [
        Property(
          "url", .string,
          "Where to POST. Each delivery is a JSON body of `{\"type\": …, \"data\": …}`.",
          required: true),
        Property(
          "events", .array(of: .string),
          "The events to subscribe to, or `[\"*\"]` for all of them. Each name must be one "
            + "the server emits: `new-message`, `updated-message`, `message-send-error`, "
            + "`group-name-change`, `group-icon-changed`, `group-icon-removed`, "
            + "`participant-removed`, `participant-added`, `participant-left`, "
            + "`chat-read-status-changed`, `typing-indicator`, `scheduled-message-error`, "
            + "`server-update`, `new-server`, `new-findmy-location`, `hello-world`, "
            + "`incoming-facetime`, `ft-call-status-changed`, `imessage-alias-removed`, and "
            + "the six theme and settings backup events.", required: true),
        Property(
          "followRedirects", .boolean,
          "Follow a 3xx from the target. Defaults to false. `follow_redirects` is read too."),
      ],
      example: .obj([
        ("url", .string("https://example.com/bluebubbles")),
        (
          "events",
          .array([
            .string("new-message"), .string("updated-message"),
            .string("message-send-error"),
          ])
        ),
        ("followRedirects", .bool(false)),
      ])),

    .webhookUpdate: Body(
      summary:
        "Changes a registered webhook. Every field is optional and ABSENT MEANS LEAVE IT: a "
        + "body carrying only `events` must not blank the URL, and a client re-registering "
        + "after a reinstall must not disarm a switch the operator set.",
      properties: [
        Property("url", .string, "A new destination. Absent leaves the current one."),
        Property(
          "events", .array(of: .string),
          "A new subscription list, replacing the old one. Absent leaves it; an empty array "
            + "is a real value and subscribes to nothing. Names are validated exactly as on "
            + "the create."),
        Property(
          "followRedirects", .boolean,
          "Change the redirect policy. Absent leaves it. `follow_redirects` is read too."),
      ],
      example: .obj([
        ("url", .string("https://example.com/bluebubbles/v2")),
        ("events", .array([.string("*")])),
      ]),
      required: false),

    .fcmRegisterDevice: Body(
      summary:
        "Registers a device for push notifications, or refreshes the token of one already "
        + "registered: the row is keyed by the token, so re-posting updates the name and the "
        + "last-seen time rather than adding a second entry.",
      properties: [
        Property(
          "name", .string,
          "What to call the device in the server's device list. Required: the handler would "
            + "fall back to `Unknown Device`, but the validation layer refuses a request "
            + "without it, so nothing can reach that fallback.", required: true),
        Property(
          "identifier", .string,
          "The FCM registration token. `token` is accepted as an alias; send one.",
          required: true),
        Property(
          "token", .string,
          "The same token under the other name some clients send. Either is read."),
      ],
      example: .obj([
        ("name", .string("Pixel 9")),
        ("identifier", .string("fcm-registration-token-goes-here")),
      ])),

    .icloudChangeAlias: Body(
      summary:
        "Changes which of this Apple Account's addresses outgoing messages are sent from. "
        + "Checked against the account's own alias list first: IMCore accepts an address "
        + "that is not on it, keeps sending from the old one, and reports nothing.",
      properties: [
        Property(
          "alias", .string,
          "The address to send from. Must be one that `GET icloud/account` reports: its "
            + "`aliases` and `vetted_aliases` are arrays of OBJECTS, and the value to send "
            + "is an entry's `Alias`.", required: true)
      ],
      example: .obj([("alias", .string("someone@example.com"))])),

    // MARK: Conversation state, macOS 26

    .chatMute: Body(
      summary:
        "Mutes a conversation and answers with the resulting state. THREE WAYS TO SAY WHEN, "
        + "and sending none of them mutes indefinitely, which is what Messages' own Hide "
        + "Alerts does and should not need a magic value.",
      properties: [
        Property(
          "mutedUntil", .anything,
          "When the mute lifts: epoch MILLISECONDS, or an ISO 8601 string. Absolute, so a "
            + "device with a skewed clock is computing the instant itself."),
        Property(
          "durationSeconds", .number,
          "How long to mute for, counted from the SERVER's clock. This is the one to send "
            + "from a phone: it is what keeps a one-hour mute from arriving already expired."),
        Property(
          "indefinite", .boolean,
          "`true` mutes until something unmutes it, and wins over the other two. The same as "
            + "sending none of them, for a client that would rather say so."),
        Property(
          "syncToPairedDevice", .boolean,
          "Push the change to the user's other devices. Defaults to true, which is what "
            + "Messages' own toggle does."),
      ],
      examples: [
        Example(
          "hide-alerts",
          "Mute until something unmutes it.",
          "The common case, and the one an empty body already does. Sending `indefinite` "
            + "says so out loud rather than relying on the absence of the other fields.",
          .obj([("indefinite", .bool(true)), ("syncToPairedDevice", .bool(true))])),
        Example(
          "for-an-hour",
          "Mute for a fixed length of time.",
          "Relative, so the server does the arithmetic. A phone computing the instant itself "
            + "is how a one-hour mute becomes one that already lapsed.",
          .obj([("durationSeconds", .int(3600))])),
        Example(
          "until-a-moment",
          "Mute until a particular time.",
          "Epoch milliseconds, matching every other timestamp on this API; an ISO 8601 "
            + "string is accepted too, because half the clients that reach this server send "
            + "those.",
          .obj([("mutedUntil", .int(1_788_440_082_220))])),
      ],
      required: false),

    .chatSetFilter: Body(
      summary:
        "Moves a conversation between the sidebar's filter buckets. Only the three buckets "
        + "this Mac has been observed to use are accepted: IMCore takes any number, and a "
        + "conversation put in a bucket Messages has no row for leaves the inbox and appears "
        + "nowhere, with a 200 saying it worked.",
      properties: [
        Property(
          "category", .integer,
          "`0` inbox, `1` unknown senders, `2` junk. Anything else is refused, naming the "
            + "three.", required: true)
      ],
      example: .obj([("category", .int(0))])),

    .chatClearHistory: Body(
      summary:
        "Deletes every message in a conversation, on every device on this account. NOT "
        + "reversible, and the confirmation is in the BODY on purpose: a query parameter "
        + "gets copied from one request to the next, and this is one typo away from emptying "
        + "a conversation nobody meant to touch.",
      properties: [
        Property(
          "confirm", .boolean,
          "Must be `true`. Anything else, the field absent included, is refused with the "
            + "reason.", required: true)
      ],
      example: .obj([("confirm", .bool(true))])),

    // MARK: Find My

    .findmyRefreshFriend: Body(
      summary:
        "Asks Apple for one friend's location now, rather than waiting for the next "
        + "broadcast. Rate limited: a refresh that comes too soon answers 200 with the "
        + "CACHED location and `metadata.refreshed` false, plus the seconds to wait.",
      properties: [
        Property(
          "address", .string,
          "The friend to locate, as their handle appears in `GET icloud/findmy/friends`.",
          required: true)
      ],
      example: .obj([("address", .string("+15551234567"))])),

    .findmyRequestShare: Body(
      summary:
        "Asks someone to share their location with this account. Answers as soon as the "
        + "invitation is sent; whether it is accepted happens on their device, minutes or "
        + "days later, so nothing here reports that it was.",
      properties: [
        Property(
          "address", .string,
          "Who to ask. A phone number or email address they use with Find My.", required: true)
      ],
      example: .obj([("address", .string("+15551234567"))])),

    .findmyStartSharing: Body(
      summary:
        "Shares this Mac's location with a conversation, or with one person in it. Behind "
        + "the `findmy_location_sharing` feature switch: with it off the route answers 403 "
        + "and names the setting.",
      properties: [
        chatGUID(
          "The conversation to share with. Required even when `address` names one person: "
            + "IMCore uses the chat to pick which of this account's addresses the offer is "
            + "sent from, and there is no chat-less form of the call."),
        Property(
          "address", .string,
          "One participant to share with. Absent shares with everyone in the chat."),
        Property(
          "duration", .string,
          "`one-hour`, `until-end-of-day` or `indefinitely`. Defaults to `one-hour`. The "
            + "three IMCore accepts and no more: any other value produces an indefinite "
            + "share, which is not what a client asking for an hour meant."),
      ],
      example: .obj([
        ("chatGuid", .string("iMessage;-;+15551234567")),
        ("duration", .string("one-hour")),
      ])),

    .findmyStopSharing: Body(
      summary:
        "Stops sharing this Mac's location with a conversation, or with one person in it. "
        + "Behind the same feature switch as the start.",
      properties: [
        chatGUID("The conversation to stop sharing with."),
        Property(
          "address", .string,
          "One participant to stop sharing with. Absent stops sharing with everyone in the "
            + "chat."),
      ],
      example: .obj([("chatGuid", .string("iMessage;-;+15551234567"))])),

    // MARK: Notification hydration

    .messageHydrate: Body(
      summary:
        "Turns the message GUIDs a push notification carries into the message rows "
        + "themselves, in one request rather than one per message. A GUID that no longer "
        + "resolves is omitted rather than failing the batch, so `metadata.requested` and "
        + "`metadata.returned` are worth comparing.",
      properties: [
        Property(
          "guids", .array(of: .string),
          "The messages to fetch, at most 100. Deduplicated in order, so a burst of "
            + "notifications for the same message costs one lookup. An empty list is a 400.",
          required: true),
        Property(
          "withAttachments", .boolean,
          "Load each message's attachments. Off by default, which keeps the response small "
            + "on the radio a notification just woke up."),
      ],
      example: .obj([
        (
          "guids",
          .array([
            .string("4D50CFE4-87A5-49D6-9687-4A5D6C94A29B"),
            .string("B1F0A7C2-5E3D-4A19-9C48-7D2E6B0F3A51"),
          ])
        ),
        ("withAttachments", .bool(true)),
      ])),

    // MARK: Access control

    .securityAllow: Body(
      summary:
        "Adds an address or a range to the permanent allowlist, so failed-authentication "
        + "lockouts never apply to it. An entry that could never match anything is REFUSED "
        + "rather than stored: the person who added it would otherwise believe they were "
        + "covered.",
      properties: [
        Property(
          "cidr", .string,
          "A single address or a CIDR block. `address` is accepted as an alias; send one.",
          required: true),
        Property(
          "address", .string,
          "The same value under the other name. Either is read."),
        Property(
          "note", .string,
          "Why the entry exists, shown beside it on the Security page. Worth writing: the "
            + "list outlives the reason."),
      ],
      example: .obj([
        ("cidr", .string("192.168.1.0/24")),
        ("note", .string("Home network")),
      ])),

    // MARK: Enrollment, continued

    .authRegister: Body(
      summary:
        "Enrols a client and answers with a `client_id` and `client_secret`. The secret is "
        + "returned ONCE and stored hashed, so the server cannot reissue it; a client that "
        + "loses it enrols again. Registered only when `auth_mode` is not `password` — under "
        + "the default this path does not exist and answers 404.",
      properties: [
        Property(
          "device_name", .string,
          "What to call this client in the server's device list.", required: true),
        Property(
          "platform", .string,
          "The client's platform, for the same list. Defaults to `unknown`."),
        Property(
          "enrollment_code", .string,
          "A one-time code, for a user who would rather not type the server password into a "
            + "client. The alternative to authenticating this request with the password."),
        Property(
          "publicKey", .string,
          "The client's X25519 public key, base64. Exactly 32 bytes decoded: a wrong length "
            + "is rejected here rather than at the first send, where it would look like a "
            + "delivery problem."),
        Property(
          "supportedCodecs", .array(of: .string),
          "The notification payload codecs this client can read, so the server can pick one "
            + "it understands rather than assuming."),
      ],
      example: .obj([
        ("device_name", .string("Pixel 9")),
        ("platform", .string("android")),
      ])),

    .authToken: Body(
      summary:
        "Exchanges the credentials enrollment handed back for an access token. A rejected "
        + "exchange is counted against the same lockout as every other credential on this "
        + "server, and answers one sentence for every failure: naming which half was wrong "
        + "would enumerate valid client ids.",
      properties: [
        Property(
          "grant_type", .string,
          "`client_credentials`, the only supported grant. Defaults to it; anything else is "
            + "refused rather than quietly answered with a token."),
        Property("client_id", .string, "From enrollment.", required: true),
        Property("client_secret", .string, "From enrollment.", required: true),
      ],
      example: .obj([
        ("grant_type", .string("client_credentials")),
        ("client_id", .string("F2A7C1D0-93B4-4E6A-8C15-0D7E2B9A4F38")),
        ("client_secret", .string("the-secret-enrollment-returned")),
      ])),

    .authRotate: Body(
      summary:
        "Replaces a client's secret, authenticated with the CURRENT one, and answers with "
        + "the new pair. The old secret stops working, so rotate and store before the next "
        + "token exchange.",
      properties: [
        Property("client_id", .string, "The client to rotate.", required: true),
        Property(
          "client_secret", .string,
          "The secret being replaced. This is the credential the request is authenticated "
            + "with, so a wrong one is a 401 rather than a 400.", required: true),
      ],
      example: .obj([
        ("client_id", .string("F2A7C1D0-93B4-4E6A-8C15-0D7E2B9A4F38")),
        ("client_secret", .string("the-secret-being-replaced")),
      ])),
  ]

  /// Write routes that take NO body, and why.
  ///
  /// Declared rather than left out, because "this route has no documented input" and "nobody
  /// has documented this route" look identical in the emitted file — and the reason is
  /// EMITTED, as a sentence in the operation's description, so a reader asking "what do I
  /// send here?" is answered rather than left to infer it from an absence. Every write route
  /// has to appear in one table or the other; `RequestBodyTests` fails the build otherwise.
  ///
  /// Each entry is read by a client author, so it says what the route does with what it
  /// already has — the path, a query parameter — rather than merely asserting that the body
  /// is empty.
  public static let bodyless: [HandlerID: String] = [
    .chatPin: "The conversation is the path; pinning takes no options.",
    .chatUnpin: "The conversation is the path; unpinning takes no options.",
    .chatFetchBackground: "The conversation is the path. `?wait=` is a query parameter.",
    .chatDelete: "The conversation is the path. It is deleted on every device on this account.",
    .chatLeave: "The conversation is the path; leaving takes no options.",
    .chatMarkRead: "The conversation is the path. Marks everything in it read.",
    .chatMarkUnread: "The conversation is the path. Marks it unread.",
    .chatShareContact:
      "The conversation is the path. Shares this account's own contact card with it; ask "
      + "`GET :guid/share/contact/status` first, which says whether it is worth doing.",
    .chatStartTyping: "The conversation is the path. Starts the typing indicator.",
    .chatStopTyping: "The conversation is the path. Stops the typing indicator.",
    .chatRemoveGroupIcon: "The conversation is the path. Removes the group photo.",
    .chatDeleteMessage:
      "Both identifiers are in the path: the conversation, then the message inside it.",
    .messageNotify:
      "The message is the path. Asks Messages to notify the recipient about it again, which "
      + "is what the app's Notify Anyway does.",
    .scheduleDelete: "The scheduled message is `:id` in the path.",
    .webhookDelete: "The webhook is `:id` in the path.",
    .macLock: "Locks this Mac's screen. That is the entire request.",
    .macRestartMessages: "Restarts Messages.app. Nothing to configure.",
    .serverInstallUpdate:
      "Installs the update `GET server/update/check` reported. `?wait=` is a query parameter: "
      + "it decides whether the response waits for the install or returns as soon as it "
      + "starts.",
    .findmyRefreshDevices:
      "Refreshes the Find My device cache. Rate limited, and a refresh that comes too soon "
      + "answers with the cached devices rather than an error.",
    .findmyRefreshFriends: "Refreshes every friend's location. Rate limited, like the devices.",
    .facetimeNewSession: "Starts a FaceTime session. Nothing to configure.",
    .facetimeAnswer: "The call is `:call_uuid` in the path.",
    .facetimeLeave: "The call is `:call_uuid` in the path. Answers 201, not 200.",
    .facetimeCleanup: "Means `clear everything this server minted, now`.",
    .facetimeRestart: "Restarts FaceTime.app. Nothing to configure.",
    .facetimeDismissAlert: "Dismisses whatever alert FaceTime.app is showing.",
    .facetimeHandoff: "The call is `:call_uuid` in the path.",
    .securityClearBlocked: "Clears the whole blocklist. That is the entire request.",
    .securityUnblock: "The entry is `:id` in the path.",
    .securityDisallow: "The entry is `:id` in the path.",
  ]

  /// One `fields` entry of a Game Pigeon example: the name/value pair every entry is.
  private static func field(_ name: String, _ value: String) -> OrderedJSON {
    .obj([("name", .string(name)), ("value", .string(value))])
  }

  /// The declaration as an OpenAPI schema.
  ///
  /// A batch body is the same object wrapped in an array, with the summary moved out to the
  /// array so a reader meets it before the element's fields rather than inside them.
  /// - Parameter validation: the route's rule set when the reference validates its body,
  ///   which then decides what is required and what values are allowed. The declarations
  ///   here say the same thing a second time, and two tables kept by hand had already come
  ///   apart: `tempGuid` and `method` on `POST /message/text` were required here and are not
  ///   to the server.
  public static func schema(for body: Body, validation: ValidationRuleSet? = nil) -> OrderedJSON {
    let rules = validation.map { set in
      Dictionary(set.fields.map { ($0.field, $0.rules) }, uniquingKeysWith: +)
    }
    func isRequired(_ property: Property) -> Bool {
      guard let rules else { return property.isRequired }
      return rules[property.name]?.contains { $0 == .required || $0 == .present } ?? false
    }
    func allowed(_ property: Property) -> [String]? {
      for case .inList(let values) in rules?[property.name] ?? [] { return values }
      return nil
    }
    let required = body.properties.filter(isRequired)
    let object = OrderedJSON.obj([
      ("type", .string("object")),
      ("description", body.isBatch ? nil : .string(body.summary)),
      (
        "properties",
        .object(
          body.properties.map { property in
            (
              property.name,
              schema(for: property.schema, property.description, allowed: allowed(property))
            )
          })
      ),
      ("required", required.isEmpty ? nil : .array(required.map { .string($0.name) })),
    ])
    guard body.isBatch else { return object }
    return .obj([
      ("type", .string("array")),
      ("description", .string(body.summary)),
      ("items", object),
    ])
  }

  static func schema(for schema: Schema, _ description: String, allowed: [String]? = nil)
    -> OrderedJSON
  {
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
        ("enum", allowed.map { .array($0.map(OrderedJSON.string)) }),
      ])
    }
  }
}
