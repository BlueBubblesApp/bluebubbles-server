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

  public struct Body: Sendable {
    public let summary: String
    /// The shape of `data`. An array route declares its ELEMENT here and sets `isArray`.
    public let properties: [Property]
    public let isArray: Bool
    /// A real response, trimmed. What a client author reads first.
    public let example: OrderedJSON

    public init(
      summary: String, properties: [Property], isArray: Bool = false, example: OrderedJSON
    ) {
      self.summary = summary
      self.properties = properties
      self.isArray = isArray
      self.example = example
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

  public static let byHandler: [HandlerID: Body] = [
    .stickerList: Body(
      summary:
        "Every sticker on the requested shelves, newest first. `metadata` carries `saved` "
        + "and `recent` totals whatever `?source=` asked for, so one request is enough to "
        + "render both sections and page either.",
      properties: stickerProperties,
      isArray: true,
      example: .array([stickerExample])),

    .stickerDetail: Body(
      summary: "One sticker, with every representation it has.",
      properties: stickerProperties,
      example: stickerExample),

    .stickerSave: Body(
      summary:
        "The sticker as the store now holds it — read back rather than echoed, so the "
        + "`identifier` is one the read routes accept and the representation carries the "
        + "UTI and size the store derived from the bytes. It lands on the `recent` shelf.",
      properties: stickerProperties,
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
  ]

  /// The declaration as the schema for `data`.
  public static func schema(for body: Body) -> OrderedJSON {
    let element = RequestBodies.schema(
      for: RequestBodies.Body(
        summary: body.summary, properties: body.properties, example: body.example
      ))
    guard body.isArray else { return element }
    return .obj([
      ("type", .string("array")),
      ("description", .string(body.summary)),
      ("items", element),
    ])
  }
}
