//  ResponseBodies
//  The `data` a route answers with, where no fixture can describe it.
//
//  The mirror of `RequestBodies`, and it exists for the same reason. Every response schema
//  in this document is INFERRED from a recorded fixture, and the conformance recorder
//  replays against the Node server — so a route that only exists here has no recording, no
//  inferred `data`, and reaches the document as a bare `ResponseEnvelope`: status, message,
//  metadata, and nothing about the payload. A client author can see the route exists and
//  not one field it returns.
//
//  For most of these routes a fixture is not merely missing but impossible. The sticker
//  library reads a Core Data store Apple owns, in a container that only exists on a Mac
//  that has had a sticker; a fixture for it would be a hand-built copy of a schema we do
//  not control, which pins the shape of the fake rather than of the real thing.
//
//  So the shape is declared, and the same rules as the request table keep it honest, both
//  enforced by `ResponseBodyTests`:
//
//  1. A declaration only applies where inference produced NOTHING. It never overrides a
//     recorded response — a fixture is evidence and this is testimony.
//  2. Every field carries a description, and every route carries an `example` taken from a
//     real response off a live Mac rather than invented.

import BBHTTPAPI

public enum ResponseBodies {

  /// Reuses the request table's schema vocabulary — the shapes are the same, and a second
  /// parallel enum would be two places to add "array of object" to.
  public typealias Schema = RequestBodies.Schema
  public typealias Property = RequestBodies.Property

  /// What a route's `data` is.
  ///
  /// Four shapes rather than a bag of flags, because they are genuinely different claims —
  /// and `mirrors` is the one that matters most: several v2 routes answer with the SAME
  /// serialized message row as `POST /api/v1/message/text`, whose schema is recorded. Saying
  /// so reuses that evidence instead of transcribing fifty fields by hand, and it cannot
  /// drift from what the serializer actually emits.
  public indirect enum Kind: Sendable {
    /// A JSON object with these fields.
    case object([Property])
    /// A JSON array whose elements have these fields.
    case list([Property])
    /// `null` — the route did the thing and has nothing to report.
    case empty
    /// The same `data` as this handler, whose schema is recorded.
    case mirrors(HandlerID)
  }

  public struct Body: Sendable {
    public let summary: String
    public let kind: Kind
    /// A real response, trimmed. Absent for an empty or mirrored one, where there is either
    /// nothing to show or a recorded schema already showing it.
    public let example: OrderedJSON?

    public init(summary: String, kind: Kind, example: OrderedJSON? = nil) {
      self.summary = summary
      self.kind = kind
      self.example = example
    }

    /// Answers with `data: null`.
    public static func empty(_ summary: String) -> Body {
      Body(summary: summary, kind: .empty, example: .null)
    }

    /// Answers with the same `data` as `handler`.
    public static func mirroring(_ handler: HandlerID, _ summary: String) -> Body {
      Body(summary: summary, kind: .mirrors(handler))
    }

    var properties: [Property] {
      switch kind {
      case .object(let properties), .list(let properties): properties
      case .empty, .mirrors: []
      }
    }
  }

  /// One sticker, as every sticker-library route reports one.
  ///
  /// Declared once and shared, because the list, the detail read and the save all answer
  /// with exactly this — which is the point: a client writes one decoder.
  private static let stickerProperties: [Property] = [
    Property(
      "identifier", .string,
      "The sticker's own UUID, and the `:id` every other sticker route takes.",
      required: true),
    Property(
      "shelf", .string,
      "`saved` for the sticker drawer, `recent` for recently used. Emoji and Memoji "
        + "stickers only ever appear as `recent`.", required: true),
    Property(
      "external_uri", .string,
      "Where the sticker came from: `sticker:///emoji/identifier/😭`, "
        + "`sticker:///memoji/cow/…`, or `sticker:///user/identifier/<UUID>`.",
      required: true),
    Property(
      "kind", .string,
      "The external URI's source, parsed for you: `emoji`, `memoji`, `user`, or `unknown` "
        + "for a source this server does not recognise.", required: true),
    Property("name", .string, "The sticker's own name. Usually null — Messages leaves it empty."),
    Property(
      "accessibility_name", .string,
      "What VoiceOver reads, e.g. `loudly crying face`. The only searchable text the store "
        + "keeps, so it is what a client should filter on."),
    Property("search_text", .string, "Additional search text. Usually null."),
    Property("byte_count", .integer, "Total size of every representation.", required: true),
    Property(
      "effect", .integer,
      "`-1` for a plain sticker; `0` or more when an effect is applied.", required: true),
    Property("created_at", .integer, "When it entered the store, epoch MILLISECONDS."),
    Property("last_used_at", .integer, "When it was last sent, epoch MILLISECONDS."),
    Property(
      "library_index", .number,
      "The store's own ordering value within a shelf. Larger is newer, and it is what the "
        + "list is sorted by — it does not always agree with `last_used_at`."),
    Property("attribution_name", .string, "Shown on the sticker detail sheet, e.g. `Stickers`."),
    Property("attribution_bundle_id", .string, "The balloon bundle id behind that attribution."),
    Property(
      "representations",
      .array(
        of: .object(properties: [
          Property("identifier", .string, "The representation's own UUID.", required: true),
          Property(
            "role", .string,
            "`com.apple.stickers.role.still`, `com.apple.stickers.role.keyboard`, or an EMPTY "
              + "string for a sticker with a single rendition. Send it back as `?role=`.",
            required: true),
          Property(
            "uti", .string, "The store's uniform type identifier, e.g. `public.heic`.",
            required: true),
          Property(
            "mime_type", .string, "That UTI as a MIME type, so a client need not map it.",
            required: true),
          Property("width", .number, "Width the store draws it at. Not always integral."),
          Property("height", .number, "Height, same unit."),
          Property("byte_count", .integer, "This rendition's size."),
          Property(
            "is_preferred", .boolean,
            "The rendition `:id/image` serves when no role is asked for.", required: true),
        ])),
      "Every rendition the store holds. A sticker Messages made has two — a full-size "
        + "`still` and a small `keyboard` preview; an emoji sticker has one.",
      required: true),
  ]

  /// A real sticker off a live Mac, trimmed to one representation.
  private static let stickerExample: OrderedJSON = .obj([
    ("identifier", .string("7608FF1D-006B-4E00-B15A-DDB5001BCBF6")),
    ("shelf", .string("recent")),
    (
      "external_uri",
      .string("sticker:///memoji/cow/cow_smiling_face_with_heart-shaped_eyes")
    ),
    ("kind", .string("memoji")),
    ("name", .null),
    ("accessibility_name", .string("Smiling face with heart-shaped eyes")),
    ("search_text", .null),
    ("byte_count", .int(109_962)),
    ("effect", .int(-1)),
    ("created_at", .int(1_788_393_987_536)),
    ("last_used_at", .int(1_788_393_987_536)),
    ("library_index", .double(13312)),
    ("attribution_name", .string("Stickers")),
    (
      "attribution_bundle_id",
      .string(
        "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:"
          + "com.apple.Stickers.UserGenerated.MessagesExtension")
    ),
    (
      "representations",
      .array([
        .obj([
          ("identifier", .string("6F696C19-523D-4F5C-B0F4-15C3317BB676")),
          ("role", .string("")),
          ("uti", .string("public.png")),
          ("mime_type", .string("image/png")),
          ("width", .double(420)),
          ("height", .double(420)),
          ("byte_count", .int(109_962)),
          ("is_preferred", .bool(true)),
        ])
      ])
    ),
  ])

  /// A `{name, value}` pair, which is how every app payload's fields travel.
  ///
  /// An ORDERED list rather than a map, and the description says so, because a repeated
  /// name is legal in a query string and some games depend on the order.
  private static let payloadFields = Property(
    "fields",
    .array(
      of: .object(properties: [
        Property("name", .string, "The field's name.", required: true),
        Property("value", .string, "Its value. An empty string is a real value.", required: true),
      ])),
    "The payload's fields, in the order they appeared. Repeated names are legal.",
    required: true)

  public static let byHandler: [HandlerID: Body] = [
    .stickerList: Body(
      summary:
        "Every sticker on the requested shelves, newest first. `metadata` carries `saved` "
        + "and `recent` totals whatever `?source=` asked for, so one request is enough to "
        + "render both sections and page either.",
      kind: .list(stickerProperties),
      example: .array([stickerExample])),

    .stickerDetail: Body(
      summary: "One sticker, with every representation it has.",
      kind: .object(stickerProperties),
      example: stickerExample),

    .stickerSave: Body(
      summary:
        "The sticker as the store now holds it — read back rather than echoed, so the "
        + "`identifier` is one the read routes accept and the representation carries the "
        + "UTI and size the store derived from the bytes. It lands on the `recent` shelf.",
      kind: .object(stickerProperties),
      example: .obj([
        ("identifier", .string("EADAA97E-1126-409E-9000-74BD19B39E32")),
        ("shelf", .string("recent")),
        (
          "external_uri",
          .string("sticker:///user/identifier/8A7657D3-E58A-440B-8FCA-7F4389F49DEA")
        ),
        ("kind", .string("user")),
        ("name", .string("BB Test")),
        ("accessibility_name", .string("teal circle")),
        ("search_text", .null),
        ("byte_count", .int(528)),
        ("effect", .int(-1)),
        ("created_at", .int(1_788_396_119_000)),
        ("last_used_at", .int(1_788_396_119_000)),
        ("library_index", .double(14336)),
        ("attribution_name", .string("Stickers")),
        ("attribution_bundle_id", .null),
        (
          "representations",
          .array([
            .obj([
              ("identifier", .string("2E9C7A10-4D3B-41F8-9A62-0C5B7E1D8F44")),
              ("role", .string("")),
              ("uti", .string("public.png")),
              ("mime_type", .string("image/png")),
              ("width", .double(160)),
              ("height", .double(160)),
              ("byte_count", .int(528)),
              ("is_preferred", .bool(true)),
            ])
          ])
        ),
      ])),

    // MARK: Sends
    //
    // Every one of these answers with the serialized message row that `POST message/text`
    // answers with — the SAME serializer, so the schema recorded for that route describes
    // them exactly. Mirroring it reuses that evidence rather than transcribing fifty fields
    // seven times, and it cannot drift.

    .messageSendSticker: .mirroring(
      .messageSendText, "The sticker's own message row — a sticker is an associated message."),
    .messageSendLater: .mirroring(
      .messageSendText,
      "The scheduled message's row. `scheduleType` 2 and `scheduleState` 1 or 2 mark it as "
        + "pending; it is not delivered yet, so `dateDelivered` is null."),
    .messageCreatePoll: .mirroring(.messageSendText, "The poll's own message row."),
    .messageVotePoll: .mirroring(
      .messageSendText,
      "The VOTE's message row, not the poll's. A vote is its own message associated with "
        + "the poll's latest state."),
    .messageAddPollOption: .mirroring(
      .messageSendText,
      "The update's message row. Adding a choice re-sends the poll in its new state, so "
        + "this is that new state's message."),
    .messageSendApp: .mirroring(.messageSendText, "The app balloon's message row."),
    .messageSendGamePigeon: .mirroring(
      .messageSendText, "The Game Pigeon message's row."),

    .messagePendingScheduled: .mirroring(
      .messageQuery,
      "Every message Apple is still holding, as ordinary message rows. `dateCreated` is the "
        + "DELIVERY time rather than when it was composed, and the `?with=` relations work "
        + "as they do on message query."),

    // MARK: Routes that report nothing
    //
    // Declared rather than left bare, because `data: null` and "nobody documented this"
    // look identical in the emitted file.

    .messageReschedule: .empty(
      "Nothing. Read the message back if you need its new delivery time."),
    .messageSendScheduledNow: .empty(
      "Nothing. The message is delivered and is no longer pending."),
    .messageCancelScheduled: .empty(
      "Nothing. The pending message is deleted rather than marked cancelled, so there is no "
        + "row left to answer with."),
    .chatPin: .empty("Nothing. Read the conversation back to confirm the pin."),
    .chatUnpin: .empty("Nothing. The conversation is no longer pinned."),
    .authRevoke: .empty("Nothing. The device's token no longer authenticates."),
    .serverMarkAlertReadV2: .empty("Nothing. The named alerts are marked read."),
    .securityClearBlocked: .empty("Nothing. The blocklist is empty."),
    .securityUnblock: .empty("Nothing. That entry is no longer blocked."),
    .securityDisallow: .empty("Nothing. That entry is no longer allowlisted."),

    // MARK: Reads this server added

    .messagePoll: Body(
      summary:
        "A poll assembled from its whole message thread: the options from the latest state, "
        + "and one newest vote per participant. The server keeps no poll state — this is "
        + "read from chat.db on every call.",
      kind: .object([
        Property("guid", .string, "The poll's ROOT message GUID.", required: true),
        Property(
          "title", .string,
          "Accepted when the poll was created, but Messages 26 neither shows a poll title "
            + "nor keeps one — expect an empty string.", required: true),
        Property("creator_handle", .string, "Who created the poll. Null for this account."),
        Property("session_id", .string, "The poll's `MSSession` UUID."),
        Property(
          "latest_state_guid", .string,
          "What a NEW VOTE must be associated with: the newest update, or the root if there "
            + "has been none. Send this, not `guid`, when casting a vote.", required: true),
        Property(
          "options",
          .array(
            of: .object(properties: [
              Property("id", .string, "The option identifier a vote refers to.", required: true),
              Property("text", .string, "What the option says.", required: true),
              Property("creator_handle", .string, "Who added it. Null for this account."),
              Property(
                "can_be_edited", .boolean,
                "Whether the poll's creator allows this option's text to be changed.",
                required: true),
            ])),
          "The choices, in order, from the poll's latest state.", required: true),
        Property(
          "votes",
          .array(
            of: .object(properties: [
              Property("guid", .string, "The vote's own message GUID.", required: true),
              Property("handle", .string, "Who voted. Null for this account."),
              Property(
                "option_ids", .array(of: .string),
                "That participant's COMPLETE selection, not a delta. An empty array is a "
                  + "retracted vote.", required: true),
              Property("date", .integer, "When it was cast, epoch MILLISECONDS."),
            ])),
          "One entry per participant, their newest vote only.", required: true),
      ]),
      example: .obj([
        ("guid", .string("542FAC8D-24A5-4817-9DA7-76864FAB1BB0")),
        ("title", .string("")),
        ("creator_handle", .null),
        ("session_id", .string("6E2C1A2B-0F2E-4E77-9B6C-2E5A3D9F1A44")),
        ("latest_state_guid", .string("EAE71D60-F41C-4573-B931-F888009C6F37")),
        (
          "options",
          .array([
            .obj([
              ("id", .string("BB650E75-8A00-4578-BA3B-098E22C50B56")),
              ("text", .string("Red")), ("creator_handle", .null),
              ("can_be_edited", .bool(false)),
            ]),
            .obj([
              ("id", .string("9A8944AF-9941-494C-808A-11D9D76F27BC")),
              ("text", .string("Green")), ("creator_handle", .null),
              ("can_be_edited", .bool(false)),
            ]),
          ])
        ),
        (
          "votes",
          .array([
            .obj([
              ("guid", .string("28A05594-5D75-4AB5-93EB-68B0F58A7A24")),
              ("handle", .null),
              ("option_ids", .array([.string("9A8944AF-9941-494C-808A-11D9D76F27BC")])),
              ("date", .int(1_788_360_567_000)),
            ])
          ])
        ),
      ])),

    .messageAppPayload: Body(
      summary:
        "An iMessage app balloon, decoded. `payload_json` and `payload_fields` appear when "
        + "the payload is one of the two shapes the server can read, so a client never has "
        + "to base64 or percent-decode anything; `url` is always the raw payload URL.",
      kind: .object([
        Property("guid", .string, "The message's GUID.", required: true),
        Property(
          "balloon_bundle_id", .string,
          "The app's full balloon bundle id, including the team-id segment."),
        Property("app_name", .string, "The app's display name, as the sender's device wrote it."),
        Property("app_id", .integer, "The app's App Store id."),
        Property(
          "session_id", .string,
          "The `MSSession` UUID. Send it back to continue the same conversation — a game "
            + "reply MUST carry the session it answers."),
        Property("summary", .string, "The message's fallback summary text."),
        Property("caption", .string, "The line shown where the balloon cannot be drawn."),
        Property("url", .string, "The payload URL, verbatim."),
        Property(
          "payload_json", .anything,
          "The payload decoded, when it is base64 JSON. Absent otherwise."),
        Property(
          "payload_fields",
          .array(
            of: .object(properties: [
              Property("name", .string, "The field's name.", required: true),
              Property("value", .string, "Its value.", required: true),
            ])),
          "The payload decoded, when it is a query string. Absent otherwise."),
        Property(
          "game_pigeon",
          .object(properties: [
            Property("version", .integer, "Game Pigeon's own payload version.", required: true),
            Property("game", .string, "The game's short name, e.g. `pool`, `beer`."),
            Property("game_id", .string, "The game's identifier within the session."),
            payloadFields,
          ]),
          "Present only on a Game Pigeon message, with its scramble already undone. The "
            + "server does not model games — the fields are handed over as they came."),
      ]),
      example: .obj([
        ("guid", .string("E404B184-D770-4732-BDFD-B9E437EE283E")),
        (
          "balloon_bundle_id",
          .string(
            "com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ"
              + ":com.gamerdelights.gamepigeon.ext")
        ),
        ("app_name", .string("GamePigeon")),
        ("app_id", .int(1_124_197_642)),
        ("session_id", .string("2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22")),
        ("summary", .string("Let's play Cup Pong!")),
        ("caption", .string("Let's play Cup Pong!")),
        ("url", .string("data:?ver=45&data=el%3D1O%26%26yS6N2Rpa58E7Fr")),
        (
          "game_pigeon",
          .obj([
            ("version", .int(45)),
            ("game", .string("beer")),
            ("game_id", .string("frWzzfHEQ8COyfyp")),
            (
              "fields",
              .array([
                .obj([("name", .string("game")), ("value", .string("beer"))]),
                .obj([("name", .string("version")), ("value", .string("5"))]),
              ])
            ),
          ])
        ),
      ])),

    // MARK: FaceTime

    .facetimeCall: Body(
      summary:
        "The call that is now ringing, and a link anyone can join it with. The call is "
        + "placed FIRST — if the link cannot be minted the call is still up, and the error "
        + "carries the call so it can be ended deliberately.",
      kind: .object([
        Property(
          "link",
          .object(properties: [
            Property("url", .string, "The join link.", required: true),
            Property("group_uuid", .string, "The conversation the link belongs to."),
            Property("name", .string, "The link's name, when it has one."),
            Property("expiration", .integer, "When the link expires, epoch MILLISECONDS."),
          ]),
          "The join link minted for this call.", required: true),
        Property(
          "call",
          .object(properties: [
            Property("call_uuid", .string, "Pass this to leave the call.", required: true),
            Property("status", .string, "e.g. `outgoing`, `connected`.", required: true),
            Property(
              "is_video", .boolean, "False when it rings as FaceTime Audio.",
              required: true),
            Property("address", .string, "The callee, for a one-to-one call."),
            Property("group_uuid", .string, "The conversation, once one has formed."),
          ]),
          "The live call.", required: true),
      ]),
      example: .obj([
        (
          "link",
          .obj([
            ("url", .string("https://facetime.apple.com/join#v=1&p=…")),
            ("group_uuid", .string("9E3C0B77-1A44-4D2E-8F51-7C2B9D6E0A13")),
          ])
        ),
        (
          "call",
          .obj([
            ("call_uuid", .string("2B62987D-4F1C-4A2E-9C3D-6E5B1A7F0C22")),
            ("status", .string("outgoing")),
            ("is_video", .bool(true)),
            ("address", .string("+15551234567")),
          ])
        ),
      ])),

    .facetimeHandoff: Body(
      summary:
        "The link for a call this Mac just ANSWERED on your behalf. Returned immediately; "
        + "admitting joiners and dropping the Mac happen in the background, and the Mac "
        + "only leaves once somebody has actually joined.",
      kind: .object([
        Property("link", .string, "The join link. Same value as `url`.", required: true),
        Property("url", .string, "The join link.", required: true),
        Property("group_uuid", .string, "The conversation the link belongs to."),
        Property("name", .string, "The link's name, when it has one."),
        Property("expiration", .integer, "When the link expires, epoch MILLISECONDS."),
      ]),
      example: .obj([
        ("link", .string("https://facetime.apple.com/join#v=1&p=…")),
        ("url", .string("https://facetime.apple.com/join#v=1&p=…")),
        ("group_uuid", .string("9E3C0B77-1A44-4D2E-8F51-7C2B9D6E0A13")),
      ])),

    .facetimeAdmit: Body(
      summary: "Confirmation that the knocker was let in.",
      kind: .object([
        Property(
          "admitted", .boolean, "Always true; a failure is an error response.",
          required: true),
        Property("address", .string, "The handle that was admitted.", required: true),
      ]),
      example: .obj([("admitted", .bool(true)), ("address", .string("+15551234567"))])),
  ]

  /// The declaration as the schema for `data`. Nil for a mirrored one, which the document
  /// resolves against the recorded schema instead.
  public static func schema(for body: Body) -> OrderedJSON? {
    switch body.kind {
    case .mirrors:
      return nil
    case .empty:
      return .obj([("type", .string("null")), ("description", .string(body.summary))])
    case .object(let properties):
      return element(body.summary, properties)
    case .list(let properties):
      return .obj([
        ("type", .string("array")),
        ("description", .string(body.summary)),
        ("items", element("", properties)),
      ])
    }
  }

  /// An object schema. Built here rather than through `RequestBodies.schema` so that an
  /// array's ELEMENT carries no description of its own — the array already has one, and an
  /// empty `description` on every item is noise in the rendered document.
  private static func element(_ summary: String, _ properties: [Property]) -> OrderedJSON {
    .obj([
      ("type", .string("object")),
      ("description", summary.isEmpty ? nil : .string(summary)),
      (
        "properties",
        .object(properties.map { ($0.name, RequestBodies.schema(for: $0.schema, $0.description)) })
      ),
      (
        "required",
        properties.contains(where: \.isRequired)
          ? .array(properties.filter(\.isRequired).map { .string($0.name) }) : nil
      ),
    ])
  }
}
