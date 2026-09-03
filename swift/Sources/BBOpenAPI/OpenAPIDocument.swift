//  OpenAPIDocument
//  The generated OpenAPI 3.1 description of the HTTP surface.
//
//  Derived from `RouteCatalog`, which is derived from the same `RouteTable` that builds the
//  router — so the document cannot describe a route the server does not serve, and adding a
//  route to the table adds it here without anybody remembering to.
//
//  WHAT THIS DOCUMENT DOES NOT KNOW, and deliberately does not guess:
//
//    - Request and response BODY SCHEMAS. The route table has no types to reflect: handlers
//      take an `APIRequestContext` and return an untyped `JSONValue`, so there is nothing to
//      derive a schema FROM. Every operation therefore describes the envelope and leaves
//      `data` unconstrained. Filling those in is a separate job with its own source of truth
//      (the recorded fixtures) — see `FixtureCoverage`.
//
//  Two things are declared beside the table rather than inferred, because neither could ever
//  come from a recording:
//    - QUERY PARAMETERS — `QueryParameters`, keyed by handler.
//    - MULTIPART BODIES and NON-JSON RESPONSES — `MultipartBodies` and `NonJSONResponses`.
//      The latter also carries the one route whose success is 201 rather than 200, derived
//      from the handler returning `.noData` rather than special-cased by path.
//
//  Each of those is a gap a hand-written spec would paper over with a guess. An emitted
//  document that states only what the table actually knows is worth more than one that reads
//  complete and is quietly wrong in nine places.
//
//  See `.claude/docs/api.md`.

import BBAuth
import BBHTTPAPI
import Foundation

public enum OpenAPIDocument {

  public struct Options: Sendable {
    /// Goes into `info.version`. The API surface's version, not the app's.
    public var version: String
    /// Advertised in `servers`. The default port, which is what a fresh install uses.
    public var serverURL: String

    public init(version: String = "1.0.0", serverURL: String = "http://localhost:1234") {
      self.version = version
      self.serverURL = serverURL
    }
  }

  public enum GenerationError: Error, CustomStringConvertible {
    case duplicateOperationID(String, first: String, second: String)

    public var description: String {
      switch self {
      case .duplicateOperationID(let id, let first, let second):
        "Two routes generate operationId '\(id)': \(first) and \(second). "
          + "operationId must be unique — fix `operationID(for:)`."
      }
    }
  }

  // MARK: - Entry point

  public static func generate(
    entries: [RouteCatalog.Entry] = RouteCatalog.routes,
    options: Options = Options()
  ) throws -> OrderedJSON {

    // Group operations by templated path, preserving first-seen path order so the
    // document reads in registration order rather than alphabetically. Registration order
    // is what the table is organised around and what its comments explain.
    var pathOrder: [String] = []
    var byPath: [String: [(method: String, operation: OrderedJSON)]] = [:]
    var seenOperationIDs: [String: String] = [:]

    for entry in entries {
      let templated = templatize(entry.path).path
      if byPath[templated] == nil { pathOrder.append(templated) }

      let id = operationID(for: entry)
      let signature = "\(entry.route.method.rawValue) \(entry.path)"
      if let existing = seenOperationIDs[id] {
        throw GenerationError.duplicateOperationID(id, first: existing, second: signature)
      }
      seenOperationIDs[id] = signature

      byPath[templated, default: []].append(
        (entry.route.method.rawValue.lowercased(), operation(for: entry, id: id))
      )
    }

    let paths = OrderedJSON.object(
      pathOrder.map { path in
        (
          key: path,
          value: OrderedJSON.object(
            (byPath[path] ?? []).map { (key: $0.method, value: $0.operation) }
          )
        )
      }
    )

    return .obj([
      ("openapi", .string("3.2.0")),
      ("info", info(options)),
      (
        "servers",
        .array([
          .obj([
            ("url", .string(options.serverURL)),
            ("description", .string("A BlueBubbles server on its default port.")),
          ])
        ])
      ),
      ("tags", tags(entries)),
      ("security", globalSecurity()),
      ("paths", paths),
      ("components", components()),
    ])
  }

  // MARK: - Info

  private static func info(_ options: Options) -> OrderedJSON {
    .obj([
      ("title", .string("BlueBubbles Server API")),
      ("version", .string(options.version)),
      (
        "description",
        .string(
          """
          The BlueBubbles server HTTP API.

          ## Versions

          `/api/v1` is the surface inherited from the previous Node/Electron server. It \
          is frozen: a bug fix belongs in v1, new capability does not.

          `/api/v2` is everything this server does that the previous one did not. Its \
          routes are individually gated — see `x-availability` on each operation — so a \
          default-configured server serves none of them.

          ## Reading the payload schemas

          Handlers exchange untyped JSON rather than a declared type, so a schema here \
          describes the payloads this API is known to produce. Read one as a lower bound:

          - A field typed `null` may carry a value in cases this document does not cover.
          - An array with empty `items` has no described element type.
          - `required` under-claims rather than over-claims: a field it does not list \
          may still always be present.
          - Where a payload could not be described unambiguously, the schema is empty \
          rather than confidently wrong.

          Some routes describe only their surface — method, path, parameters and status \
          codes — with no payload schema.

          ## What is not described

          A few routes describe their failures but not their success payload — those whose \
          success needs a live call, an available update, or an attachment that has been \
          purged to iCloud.
          """)
      ),
    ])
  }

  // MARK: - Tags

  /// Group tags, nested under a parent tag per API version.
  ///
  /// `parent` and `summary` are 3.2 additions and are the reason this document targets 3.2
  /// rather than 3.1. Before them the version had to be smuggled into the display name —
  /// `"Chat (v1)"` — because tag names are the only identifier an operation can reference and
  /// they have to be unique. Now the name is a slug nobody reads (`chat-v1`), `summary`
  /// carries the display name, and `parent` puts it under the right version. A viewer renders
  /// two top-level sections instead of thirty flat ones whose version is buried in a suffix.
  private static func tags(_ entries: [RouteCatalog.Entry]) -> OrderedJSON {
    var order: [String] = []
    var byTag: [String: (display: String, parent: String?, description: String)] = [:]
    var versions: [Int] = []

    for entry in entries {
      let name = tagName(for: entry)
      guard byTag[name] == nil else { continue }
      order.append(name)

      // The landing page is not under `/api/v<n>`, so it hangs at the top level rather than
      // claiming to be part of a version it does not mount under.
      let parent = entry.group.mountsAtRoot ? nil : "v\(entry.group.apiVersion)"
      if parent != nil, !versions.contains(entry.group.apiVersion) {
        versions.append(entry.group.apiVersion)
      }
      byTag[name] = (entry.group.name, parent, entry.availability.summary)
    }

    let parents = versions.sorted().map { version in
      OrderedJSON.obj([
        ("name", .string("v\(version)")),
        ("summary", .string("API v\(version)")),
        ("description", .string(versionDescription(version))),
        ("kind", .string("nav")),
      ])
    }

    let groups = order.map { name -> OrderedJSON in
      let tag = byTag[name]
      return .obj([
        ("name", .string(name)),
        ("summary", tag.map { .string($0.display) }),
        ("description", tag.map { .string($0.description) }),
        ("parent", tag?.parent.map { .string($0) }),
        ("kind", .string("nav")),
      ])
    }

    return .array(parents + groups)
  }

  private static func versionDescription(_ version: Int) -> String {
    switch version {
    case 1:
      return "Routes mounted under `/api/v1`."
    case 2:
      return "Routes mounted under `/api/v2`. Every one of them is individually gated — see "
        + "each operation's `x-availability` for the setting or flag that makes it reachable. "
        + "A server with default settings serves none of them."
    default:
      return "Routes mounted under `/api/v\(version)`."
    }
  }

  /// Group name plus version, because `Chat` exists in both v1 and v2 and they are not the
  /// same set of endpoints.
  /// The tag's `name`, which is an identifier rather than a label — operations reference it,
  /// so it must be unique and stable. `Chat` exists in both v1 and v2 and they are not the
  /// same set of endpoints, hence the version suffix. The human-facing string is `summary`.
  private static func tagName(for entry: RouteCatalog.Entry) -> String {
    let slug = entry.group.name
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .joined(separator: "-")
    return entry.group.mountsAtRoot ? slug : "\(slug)-v\(entry.group.apiVersion)"
  }

  // MARK: - Operations

  private static func operation(for entry: RouteCatalog.Entry, id: String) -> OrderedJSON {
    let requirements = entry.group.requirements.union(entry.route.requirements)
    let unauthenticated = requirements.contains(.unauthenticated)
    let needsHelper = requirements.contains(.privateAPI)

    var notes: [String] = [entry.availability.summary]
    if needsHelper {
      notes.append(
        "Requires the Private API helper to be connected. Without it this route "
          + "answers **500** with an `iMessage Error` — not 503."
      )
    }
    if unauthenticated {
      notes.append("No authentication required.")
    } else {
      notes.append(
        "Requires the `\(entry.route.scope.rawValue)` scope. Under the "
          + "default `auth_mode = password` the shared password grants every scope, so "
          + "this is only enforced with per-device credentials.")
    }

    return .obj([
      ("operationId", .string(id)),
      ("summary", .string(summary(for: entry))),
      ("description", .string(notes.joined(separator: "\n\n"))),
      ("tags", .array([.string(tagName(for: entry))])),
      ("parameters", parameters(for: entry)),
      ("requestBody", requestBody(for: entry, operationID: id)),
      // An empty array here means "no authentication", which is what `.unauthenticated`
      // means. Omitting the key instead would inherit the document-level `security`.
      ("security", unauthenticated ? .array([]) : nil),
      (
        "responses",
        responses(
          for: entry, operationID: id, unauthenticated: unauthenticated,
          needsHelper: needsHelper)
      ),
      ("x-handler-id", .string(entry.route.handlerID.rawValue)),
      ("x-api-version", .int(entry.group.apiVersion)),
      ("x-availability", .string(entry.availability.id)),
      // An extension rather than the operation's `security` requirement, and NOT because
      // the spec forbids it — 3.1 permits it, saying that for a non-oauth2 scheme the array
      // "MAY contain a list of role names which are required for the execution, but are not
      // otherwise defined or exchanged in-band". That permission is the problem twice over.
      // The names would carry no defined semantics against a bearer or apiKey scheme, and
      // stating them as a REQUIREMENT would tell a client it must hold `chats:write` to make
      // the call — which is false on a default server, where `auth_mode = password` means the
      // shared password grants every scope. The extension says the true thing (this is the
      // scope the route declares) without asserting a rule that is not in force.
      ("x-required-scope", unauthenticated ? nil : .string(entry.route.scope.rawValue)),
      (
        "x-request-timeout-seconds",
        .int(
          seconds(
            entry.route.requestTimeout ?? RouteTable.defaultRequestTimeout
          ))
      ),
      (
        "x-response-timeout-seconds",
        .int(
          seconds(
            entry.route.responseTimeout
              ?? entry.group.responseTimeout
              ?? RouteTable.defaultResponseTimeout
          ))
      ),
    ])
  }

  /// A declared default as the JSON type its schema claims.
  ///
  /// The table stores every default as a string because that is how they are written down;
  /// the document has to emit `100` and `false` rather than `"100"` and `"false"`, or the
  /// schema is invalid.
  private static func typedDefault(_ raw: String, as type: String) -> OrderedJSON {
    switch type {
    case "integer": Int(raw).map { OrderedJSON.int($0) } ?? .string(raw)
    case "number": Double(raw).map { OrderedJSON.double($0) } ?? .string(raw)
    case "boolean": raw == "true" ? .bool(true) : raw == "false" ? .bool(false) : .string(raw)
    default: .string(raw)
    }
  }

  private static func parameters(for entry: RouteCatalog.Entry) -> OrderedJSON {
    let names = templatize(entry.path).parameters
    var items: [OrderedJSON] = names.map { name in
      .obj([
        ("name", .string(name)),
        ("in", .string("path")),
        ("required", .bool(true)),
        ("description", .string(description(forPathParameter: name))),
        ("schema", .obj([("type", .string("string"))])),
      ])
    }
    // Declared per handler, because handlers read them by string and nothing else records
    // them. See QueryParameters.
    for parameter in QueryParameters.byHandler[entry.route.handlerID] ?? [] {
      var schema: [(String, OrderedJSON?)] = [("type", .string(parameter.type))]
      if let allowed = parameter.allowed {
        schema.append(("enum", .array(allowed.map { .string($0) })))
      }
      if let fallback = parameter.defaultValue {
        // TYPED to match the schema. JSON Schema requires `default` to be an instance of the
        // schema it sits in, and a validator says so: `'100' is not of type 'integer'`.
        schema.append(("default", typedDefault(fallback, as: parameter.type)))
      }
      items.append(
        .obj([
          ("name", .string(parameter.name)),
          ("in", .string("query")),
          ("required", .bool(parameter.description.contains("REQUIRED"))),
          ("description", .string(parameter.description)),
          ("schema", .obj(schema)),
        ]))
    }

    items.append(.obj([("$ref", .string("#/components/parameters/pretty"))]))
    return .array(items)
  }

  /// The four parameter names the table uses, spelled out. A client that guesses "guid is a
  /// message GUID" on a chat route sends the wrong thing and gets a 404 with no hint.
  private static func description(forPathParameter name: String) -> String {
    switch name {
    case "guid":
      return "The GUID of the resource this route's group is about — a chat GUID under "
        + "`/chat`, a message GUID under `/message`, an attachment GUID under "
        + "`/attachment`, a handle address under `/handle`."
    case "messageGuid": return "A message GUID."
    case "externalId": return "The contact's identifier in the source address book."
    case "id": return "The numeric or string identifier of the resource."
    case "call_uuid": return "The UUID of a FaceTime call."
    case "group_uuid": return "The UUID of a FaceTime conversation."
    default: return "Path parameter."
    }
  }

  /// The request body, when the corpus recorded one.
  ///
  /// Absent for a GET, and absent for the attachment routes even though they take one:
  /// theirs is multipart, recorded as raw text rather than parsed. Marked `required` because
  /// every recording carried a body — a route that also accepts an empty one would need a
  /// recording proving it.
  /// A multipart form, for the five routes that take a file.
  ///
  /// Declared rather than inferred: the recorder stores a multipart body as raw text, so
  /// there is nothing for the schema inference to read. Emitted as `multipart/form-data` with
  /// `format: binary` on the file fields, which is what makes a viewer offer a file picker
  /// instead of a text box.
  private static func multipartBody(for entry: RouteCatalog.Entry) -> OrderedJSON? {
    guard let fields = MultipartBodies.byHandler[entry.route.handlerID] else { return nil }
    let properties = OrderedJSON.object(
      fields.map { field in
        (
          key: field.name,
          value: OrderedJSON.obj([
            ("type", .string(field.kind == "binary" ? "string" : field.kind)),
            ("format", field.kind == "binary" ? .string("binary") : nil),
            ("description", .string(field.description)),
          ])
        )
      })
    let required = fields.filter(\.isRequired).map { OrderedJSON.string($0.name) }
    return .obj([
      ("required", .bool(true)),
      (
        "content",
        .obj([
          (
            "multipart/form-data",
            .obj([
              (
                "schema",
                .obj([
                  ("type", .string("object")),
                  ("properties", properties),
                  ("required", required.isEmpty ? nil : .array(required)),
                ])
              )
            ])
          )
        ])
      ),
    ])
  }

  private static func requestBody(for entry: RouteCatalog.Entry, operationID: String)
    -> OrderedJSON?
  {
    if let multipart = multipartBody(for: entry) { return multipart }
    return jsonRequestBody(for: entry, operationID: operationID)
  }

  /// A DECLARED body wins over an inferred one, and carries an example.
  ///
  /// Inference is the better source where a recording exists, but it can only describe what
  /// was recorded — and the routes this server added have no recording at all, so without
  /// this they reach the document with no documented input. Where both exist the declaration
  /// has to be a superset of the inferred one, which `RequestBodyTests` enforces.
  private static func jsonRequestBody(for entry: RouteCatalog.Entry, operationID: String)
    -> OrderedJSON?
  {
    if let declared = RequestBodies.byHandler[entry.route.handlerID] {
      return .obj([
        ("description", .string(schemaNote)),
        ("required", .bool(declared.isRequired)),
        (
          "content",
          .obj([
            (
              "application/json",
              .obj([
                ("schema", RequestBodies.schema(for: declared)),
                ("example", declared.example),
              ])
            )
          ])
        ),
      ])
    }
    guard let schema = FixtureSchemas.table[operationID]?.request else { return nil }
    return .obj([
      ("description", .string(schemaNote)),
      ("required", .bool(true)),
      ("content", .obj([("application/json", .obj([("schema", schema)]))])),
    ])
  }

  /// What every payload schema says about itself.
  ///
  /// Stated on the schema rather than left to the reader, because the failure mode is a
  /// client author reading `"type": "null"` as "always null" when it means "null in every
  /// payload this document covers".
  ///
  /// **Reader-facing text: say what the schema guarantees, never how it was produced.**
  /// This string and `info.description` are rendered to end users — by `APIDocsView` in the
  /// app, and by whatever viewer someone points at the committed document. How the document
  /// is built is a contributor's concern and belongs in `docs/api/README.md`, which is the
  /// contributor's doc; a caveat about provenance leaking into a published API description
  /// reads as an admission rather than as the useful warning it is meant to be.
  static let schemaNote =
    "Describes payloads this API is known to produce, not a declared type. A field typed "
    + "`null` may carry a value in cases this document does not cover, and an array with "
    + "empty `items` has no described element type."

  private static func responses(
    for entry: RouteCatalog.Entry,
    operationID: String,
    unauthenticated: Bool,
    needsHelper: Bool
  ) -> OrderedJSON {
    var pairs: [(String, OrderedJSON?)] = []

    // A route whose body is bytes, or whose success is not 200, is described from what its
    // handler RETURNS rather than being forced into the envelope. See NonJSONResponses.
    if let binary = NonJSONResponses.binary[entry.route.handlerID] {
      pairs.append(
        (
          "200",
          .obj([
            ("description", .string(binary.description)),
            (
              "content",
              .obj([
                (
                  binary.contentType,
                  .obj([
                    ("schema", .obj([("type", .string("string")), ("format", .string("binary"))]))
                  ])
                )
              ])
            ),
          ])
        ))
      return finishResponses(
        pairs, unauthenticated: unauthenticated, needsHelper: needsHelper)
    }

    if let alternate = NonJSONResponses.alternateSuccess[entry.route.handlerID] {
      pairs.append(
        (
          String(alternate.status),
          .obj([
            ("description", .string(alternate.description)),
            (
              "content",
              .obj([
                ("application/json", .obj([("schema", ref("ResponseEnvelope"))]))
              ])
            ),
          ])
        ))
      return finishResponses(
        pairs, unauthenticated: unauthenticated, needsHelper: needsHelper)
    }

    let successMessage = SuccessMessages.message(for: entry.route.handlerID) ?? "Success"
    // `allOf` rather than a standalone schema so the envelope stays defined in ONE place.
    // Inference contributes the `data` member; `status`, `message` and `metadata` are
    // hand-written and stay that way.
    //
    // A DECLARED response (`ResponseBodies`) fills in only where inference produced
    // nothing — the routes this server added, which have no fixture and would otherwise
    // document a bare envelope with no payload at all. A fixture always wins: it is
    // evidence, and a declaration is testimony.
    let declared =
      FixtureSchemas.table[operationID]?.response == nil
      ? ResponseBodies.byHandler[entry.route.handlerID] : nil
    let dataSchema =
      FixtureSchemas.table[operationID]?.response
      ?? declared.flatMap { body in
        // A MIRRORED declaration resolves against the schema recorded for the handler it
        // names, so a route answering with the same serialized row as a v1 route documents
        // that row exactly rather than a hand-copied approximation of it.
        if case .mirrors(let handler) = body.kind { return recordedResponse(of: handler) }
        return ResponseBodies.schema(for: body)
      }
    let successSchema: OrderedJSON =
      dataSchema.map { schema in
        .obj([
          ("allOf", .array([ref("ResponseEnvelope")])),
          ("description", .string(schemaNote)),
          ("properties", .obj([("data", schema)])),
        ])
      } ?? ref("ResponseEnvelope")
    pairs.append(
      (
        "200",
        .obj([
          ("description", .string("Success.")),
          (
            "content",
            .obj([
              (
                "application/json",
                .obj([
                  ("schema", successSchema),
                  (
                    "example",
                    .obj([
                      ("status", .int(200)),
                      ("message", .string(successMessage)),
                      // Only on a declared response: an inferred one came from a recorded
                      // body, and the example alongside it would be a second, unverified
                      // account of the same thing.
                      ("data", declared?.example),
                    ])
                  ),
                ])
              )
            ])
          ),
        ])
      ))

    return finishResponses(pairs, unauthenticated: unauthenticated, needsHelper: needsHelper)
  }

  /// The error half, shared by every response shape.
  ///
  /// Split out so a binary route and a 201 route get the same 401/404/500/504 contract as an
  /// envelope route — they differ in how they SUCCEED, not in how they fail.
  private static func finishResponses(
    _ initial: [(String, OrderedJSON?)],
    unauthenticated: Bool,
    needsHelper: Bool
  ) -> OrderedJSON {
    var pairs = initial

    if !unauthenticated {
      pairs.append(
        (
          "401",
          errorResponse(
            "Missing or invalid credentials.",
            status: 401, type: "Authentication Error"
          )
        ))
    }
    pairs.append(
      (
        "404",
        errorResponse(
          "No such resource. Note the error type is `Database Error`, not `Not Found` — "
            + "inherited from the previous server and part of the contract.",
          status: 404, type: "Database Error"
        )
      ))
    if needsHelper {
      pairs.append(
        (
          "500",
          errorResponse(
            "The Private API helper is not connected, or the operation failed.",
            status: 500, type: "iMessage Error"
          )
        ))
    }
    pairs.append(
      (
        "504",
        errorResponse(
          "The route exceeded its response timeout.",
          status: 504, type: "Gateway Timeout"
        )
      ))
    return .obj(pairs)
  }

  private static func errorResponse(
    _ description: String,
    status: Int,
    type: String
  ) -> OrderedJSON {
    .obj([
      ("description", .string(description)),
      (
        "content",
        .obj([
          (
            "application/json",
            .obj([
              ("schema", ref("ErrorEnvelope")),
              (
                "example",
                .obj([
                  ("status", .int(status)),
                  ("message", .string(type)),
                  (
                    "error",
                    .obj([
                      ("type", .string(type)),
                      ("message", .string("A description of what went wrong.")),
                    ])
                  ),
                ])
              ),
            ])
          )
        ])
      ),
    ])
  }

  // MARK: - Components

  private static func globalSecurity() -> OrderedJSON {
    // Alternatives, not a conjunction: an array of requirement objects is an OR. All five
    // are genuinely accepted — see `PasswordScheme.extractCredential`.
    .array([
      .obj([("passwordQuery", .array([]))]),
      .obj([("guidQuery", .array([]))]),
      .obj([("tokenQuery", .array([]))]),
      .obj([("bearerAuth", .array([]))]),
      .obj([("basicAuth", .array([]))]),
    ])
  }

  private static func components() -> OrderedJSON {
    .obj([
      (
        "securitySchemes",
        .obj([
          ("passwordQuery", apiKeyQuery("password", "The server password. The usual form.")),
          (
            "guidQuery",
            apiKeyQuery(
              "guid", "The server password, under its older parameter name. Still accepted.")
          ),
          (
            "tokenQuery",
            apiKeyQuery("token", "The server password, under a third accepted parameter name.")
          ),
          (
            "bearerAuth",
            .obj([
              ("type", .string("http")),
              ("scheme", .string("bearer")),
              ("description", .string("The server password as a bearer token.")),
            ])
          ),
          (
            "basicAuth",
            .obj([
              ("type", .string("http")),
              ("scheme", .string("basic")),
              (
                "description",
                .string(
                  "The server password as the Basic password. The username is ignored."
                )
              ),
            ])
          ),
        ])
      ),
      (
        "parameters",
        .obj([
          (
            "pretty",
            .obj([
              ("name", .string("pretty")),
              ("in", .string("query")),
              ("required", .bool(false)),
              (
                "description",
                .string(
                  "Pretty-print the JSON response. PRESENCE, not truthiness — "
                    + "`?pretty` and `?pretty=false` both turn it on."
                )
              ),
              ("schema", .obj([("type", .string("string"))])),
            ])
          )
        ])
      ),
      (
        "schemas",
        .obj([
          (
            "ResponseEnvelope",
            .obj([
              ("type", .string("object")),
              (
                "description",
                .string(
                  "The envelope every JSON response uses. `data` and `metadata` are "
                    + "OMITTED when absent, never emitted as null."
                )
              ),
              ("required", .array([.string("status"), .string("message")])),
              (
                "properties",
                .obj([
                  (
                    "status",
                    .obj([
                      ("type", .string("integer")),
                      ("description", .string("Mirrors the HTTP status code.")),
                    ])
                  ),
                  ("message", .obj([("type", .string("string"))])),
                  (
                    "data",
                    .obj([
                      (
                        "description",
                        .string(
                          "The payload. Not described in this document — see the "
                            + "description at the top."
                        )
                      )
                    ])
                  ),
                  (
                    "metadata",
                    .obj([
                      ("type", .string("object")),
                      ("description", .string("Present on paginated and refresh routes.")),
                    ])
                  ),
                ])
              ),
            ])
          ),
          (
            "ErrorEnvelope",
            .obj([
              ("type", .string("object")),
              ("required", .array([.string("status"), .string("message"), .string("error")])),
              (
                "properties",
                .obj([
                  ("status", .obj([("type", .string("integer"))])),
                  ("message", .obj([("type", .string("string"))])),
                  (
                    "error",
                    .obj([
                      ("type", .string("object")),
                      ("required", .array([.string("type"), .string("message")])),
                      (
                        "properties",
                        .obj([
                          (
                            "type",
                            .obj([
                              ("type", .string("string")),
                              ("enum", .array(errorTypes.map { .string($0) })),
                            ])
                          ),
                          ("message", .obj([("type", .string("string"))])),
                        ])
                      ),
                    ])
                  ),
                  (
                    "data",
                    .obj([
                      (
                        "description",
                        .string(
                          "Present on some failures. A failed send returns the "
                            + "serialized message here alongside a 500."
                        )
                      )
                    ])
                  ),
                ])
              ),
            ])
          ),
        ])
      ),
    ])
  }

  /// Transcribed from `ErrorType`. Not derived: the enum is not `CaseIterable`, and making
  /// it so to serve this file would be the tail wagging the dog.
  private static let errorTypes = [
    "Server Error", "Database Error", "iMessage Error", "Socket Error",
    "Validation Error", "Authentication Error", "Gateway Timeout",
  ]

  private static func apiKeyQuery(_ name: String, _ description: String) -> OrderedJSON {
    .obj([
      ("type", .string("apiKey")),
      ("in", .string("query")),
      ("name", .string(name)),
      ("description", .string(description)),
    ])
  }

  private static func ref(_ schema: String) -> OrderedJSON {
    .obj([("$ref", .string("#/components/schemas/\(schema)"))])
  }

  // MARK: - Path and identifier derivation

  /// `/chat/:guid/message` -> `/chat/{guid}/message`, plus the parameter names in order.
  ///
  /// The table uses the Express form the Node server used. OpenAPI will not accept it, and a
  /// tool given `:guid` treats it as a literal path segment.
  public static func templatize(_ path: String) -> (path: String, parameters: [String]) {
    var parameters: [String] = []
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map {
      component -> String in
      guard component.hasPrefix(":") else { return String(component) }
      let name = String(component.dropFirst())
      parameters.append(name)
      return "{\(name)}"
    }
    return (components.joined(separator: "/"), parameters)
  }

  /// A unique, stable identifier per operation.
  ///
  /// Derived from method and path rather than from `handlerID`, because handler IDs are NOT
  /// unique — `POST :guid/participant` and `POST :guid/participant/add` deliberately share
  /// `chat.addParticipant`, and `PUT /contact` and `PUT /contact/:id` share `contact.update`.
  /// The version stays in the identifier because v1 and v2 both serve `GET /server/alert`.
  /// The recorded `data` schema of another handler, for a mirrored declaration.
  ///
  /// Nil when that handler has no recording — which `ResponseBodyTests` forbids, so a
  /// mirror that resolves to nothing is a build failure rather than a silently empty
  /// response in the document.
  static func recordedResponse(of handler: HandlerID) -> OrderedJSON? {
    guard let entry = RouteCatalog.routes.first(where: { $0.route.handlerID == handler })
    else { return nil }
    return FixtureSchemas.table[operationID(for: entry)]?.response
  }

  public static func operationID(for entry: RouteCatalog.Entry) -> String {
    var words = [entry.route.method.rawValue.lowercased()]
    let templated = templatize(entry.path).path

    for component in templated.split(separator: "/") {
      if component == "api" { continue }
      if component.hasPrefix("{") {
        words.append("by")
        words.append(String(component.dropFirst().dropLast()))
      } else {
        words.append(String(component))
      }
    }
    if words.count == 1 { words.append("root") }

    // Split on the separators that appear in paths and parameter names, then camel-case.
    let parts = words.flatMap { $0.split(whereSeparator: { $0 == "-" || $0 == "_" }) }
    return parts.enumerated().map { index, part in
      index == 0 ? part.lowercased() : part.prefix(1).uppercased() + part.dropFirst()
    }.joined()
  }

  /// A placeholder summary derived from the handler ID: `chat.addParticipant` -> "Add
  /// participant". Good enough to read in a sidebar, and the thing a hand-written docs table
  /// should override first.
  private static func summary(for entry: RouteCatalog.Entry) -> String {
    let name =
      entry.route.handlerID.rawValue.split(separator: ".").last.map(String.init)
      ?? entry.route.handlerID.rawValue
    var words: [String] = []
    var current = ""
    for character in name {
      if character.isUppercase, !current.isEmpty {
        words.append(current)
        current = String(character).lowercased()
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { words.append(current) }
    guard let first = words.first else { return name }
    return
      (first.prefix(1).uppercased() + first.dropFirst() + " "
      + words.dropFirst().joined(separator: " "))
      .trimmingCharacters(in: .whitespaces)
  }

  private static func seconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds)
  }
}
