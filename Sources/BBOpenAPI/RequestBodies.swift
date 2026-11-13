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
//  The bodies are declared by route area: `RequestBodies+Messages.swift`,
//  `RequestBodies+Scheduling.swift`, `RequestBodies+Apps.swift`, `RequestBodies+Chats.swift`,
//  `RequestBodies+FaceTime.swift`, `RequestBodies+Auth.swift`, `RequestBodies+PagedReads.swift`,
//  `RequestBodies+Contacts.swift`, `RequestBodies+Server.swift`, `RequestBodies+FindMy.swift`
//  and `RequestBodies+Genmoji.swift`. This file holds the declaration model, the two helpers every
//  area shares, the merged table, the bodyless routes and the schema emission.
//
//  See `docs/api/README.md` § Request bodies.

import BBHTTPAPI
public enum RequestBodies {

  // MARK: - The declaration model

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

  // MARK: - What every area shares

  /// The field every write route takes, so the description is written once. Shared with the
  /// `RequestBodies+*.swift` area files.
  static func chatGUID(_ note: String = "The conversation to send to.") -> Property {
    Property("chatGuid", .string, note, required: true)
  }

  /// Shared with the `RequestBodies+*.swift` area files.
  static let textFormatting = Property(
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

  // MARK: - The tables

  /// Every declared body, keyed by handler.
  ///
  /// Declared by route area in the `RequestBodies+*.swift` files and merged here. A route
  /// declared in two areas traps, as a duplicate key in one literal did.
  public static let byHandler: [HandlerID: Body] = Dictionary(
    uniqueKeysWithValues: [
      messageBodies, schedulingBodies, appBodies, genmojiBodies, chatBodies, faceTimeBodies,
      authBodies,
      pagedReadBodies, contactBodies, serverBodies, findMyBodies,
    ].joined().map { ($0.key, $0.value) })

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
    .icloudStartSync:
      "Sync Now takes no options: Messages decides what to fetch and what to send.",
    .genmojiLibraryDelete:
      "The Genmoji is the path. It is removed on every device on this iCloud account.",
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

  // MARK: - Emission

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
