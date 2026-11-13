//  OpenAPIDocument+Operations
//  One operation per route: its parameters, its request body and the path-parameter prose.
//
//  Its own file so the derivation of an operation from a `RouteCatalog.Entry` is read apart
//  from the responses it ends with (`OpenAPIDocument+Responses.swift`) and the shared
//  components it refers to (`OpenAPIDocument+Components.swift`).

import BBAuth
import BBHTTPAPI
import BBLicense
import BBSerialization
import Foundation

extension OpenAPIDocument {

  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func operation(for entry: RouteCatalog.Entry, id: String) -> OrderedJSON {
    let requirements = entry.group.requirements.union(entry.route.requirements)
    let unauthenticated = requirements.contains(.unauthenticated)
    // `.optionalAuthentication` is a THIRD state and had been folded into "requires
    // authentication", which is the opposite of what it means. A credential is read if one
    // is sent and its absence is not an error: it is what the enrolment and token routes
    // use, because a client asking for its first token has nothing to authenticate with.
    // Describing those two as needing a scope and answering 401 would tell a client author
    // to do the one thing that cannot work.
    let optionalAuthentication = requirements.contains(.optionalAuthentication)
    let needsHelper = requirements.contains(.privateAPI)
    // The route's floor, not the group's: a route may raise its group's and may not lower
    // it, and `tierFloor(for:)` is the one place that resolves the pair.
    let tier = entry.group.tierFloor(for: entry.route)

    var notes: [String] = [entry.availability.summary]
    if let tier {
      notes.append(
        "Requires a **\(tier.displayName)** subscription. Without one this route answers "
          + "**402** and `error.data.reason` says which of the reasons below applies; the "
          + "rest of the API, including everything in v1, is unaffected."
      )
    }
    // SAID, not left to be inferred. A write route with no `requestBody` and a route nobody
    // documented look identical to a reader, and the difference is exactly what they came to
    // find out. `RequestBodies.bodyless` carries the sentence; `RequestBodyTests` fails the
    // build on a write route that is in neither table.
    if entry.route.method != .get, requestBody(for: entry, operationID: id) == nil,
      let reason = RequestBodies.bodyless[entry.route.handlerID]
    {
      notes.append("Takes no request body. \(reason)")
    }
    if needsHelper {
      notes.append(
        "Requires the Private API helper to be connected. Without it this route "
          + "answers **500** with an `iMessage Error`, not 503."
      )
    }
    if unauthenticated {
      notes.append("No authentication required.")
    } else if optionalAuthentication {
      notes.append(
        "Authentication is optional. A credential is checked if one is sent, and its "
          + "absence is not an error: this route is reachable before a client has one. "
          + "The blocklist still applies.")
    } else {
      // AUTHENTICATION, NOT AUTHORIZATION. This said "Requires the `messages:read` scope"
      // on 164 of the 167 operations, and that is an authorization model this server does
      // not have: `AuthenticationStage.authorize` is genuinely called from the dispatch
      // path (`HTTPServer.swift`), but no principal that LACKS a scope can be produced.
      // The password scheme hard-codes `Scope.all`; the only other producer reads a device
      // row whose scopes are written once, by the one caller of `DeviceRegistry.register`,
      // which never narrows them. So the `Forbidden` branch is unreachable under every
      // `auth_mode`, and the sentence told a client author to obtain something that cannot
      // be granted or withheld. Scopes go back in the document when something can refuse
      // one. See `docs/api/README.md` § Authentication.
      notes.append("Requires authentication: the server password, in any accepted form.")
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
      //
      // An optionally-authenticated route gets the document requirement AND the empty one,
      // which is how OpenAPI spells "either": a caller may present a credential or none.
      (
        "security",
        unauthenticated
          ? .array([])
          : (optionalAuthentication ? optionalSecurity() : nil)
      ),
      (
        "responses",
        responses(
          for: entry, operationID: id,
          unauthenticated: unauthenticated || optionalAuthentication,
          needsHelper: needsHelper, tier: tier)
      ),
      ("x-handler-id", .string(entry.route.handlerID.rawValue)),
      ("x-api-version", .int(entry.group.apiVersion)),
      ("x-availability", .string(entry.availability.id)),
      // Machine-readable beside the prose, so a generator can mark the paid surface without
      // parsing a sentence. Absent — not null — on a free route, which is every v1 route.
      ("x-minimum-tier", tier.map { OrderedJSON.string($0.id) }),
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
    let validated = Self.validation(entry, .query).map { set in
      Dictionary(set.fields.map { ($0.field, $0.rules) }, uniquingKeysWith: +)
    }
    for parameter in QueryParameters.byHandler[entry.route.handlerID] ?? [] {
      var schema: [(String, OrderedJSON?)] = [("type", .string(parameter.type))]
      // Where the reference validates this route's query, its rule set says what is
      // required. The description's "REQUIRED" is the fallback for a route it does not,
      // and had already disagreed: `after` on `GET /message/count/updated` is required by
      // the validator and was documented as optional.
      let isRequired =
        validated.map { rules in
          rules[parameter.name]?.contains { $0 == .required || $0 == .present } ?? false
        } ?? parameter.description.contains("REQUIRED")
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
          ("required", .bool(isRequired)),
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
      return "The GUID of the resource this route's group is about: a chat GUID under "
        + "`/chat`, a message GUID under `/message`, an attachment GUID under "
        + "`/attachment`, a handle address under `/handle`. An attachment resolves by its "
        + "current `guid` or by its `originalGuid`: Messages renames an attachment after the "
        + "send (a sticker's `guid` becomes `at_<n>_<message guid>`), and the GUID a client "
        + "was first told keeps working."
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
  /// every recording carried a body: a route that also accepts an empty one would need a
  /// recording proving it.
  /// A multipart form, for the five routes that take a file.
  ///
  /// Declared rather than inferred: the recorder stores a multipart body as raw text, so
  /// there is nothing for the schema inference to read. Emitted as `multipart/form-data` with
  /// `format: binary` on the file fields, which is what makes a viewer offer a file picker
  /// instead of a text box.
  private static func multipartBody(for entry: RouteCatalog.Entry) -> OrderedJSON? {
    guard let form = MultipartBodies.byHandler[entry.route.handlerID] else { return nil }
    let properties = OrderedJSON.object(
      form.fields.map { field in
        (
          key: field.name,
          value: OrderedJSON.obj([
            ("type", .string(field.kind == "binary" ? "string" : field.kind)),
            ("format", field.kind == "binary" ? .string("binary") : nil),
            ("description", .string(field.description)),
          ])
        )
      })
    let required = form.fields.filter(\.isRequired).map { OrderedJSON.string($0.name) }
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
                  ("description", .string(form.summary)),
                  ("properties", properties),
                  ("required", required.isEmpty ? nil : .array(required)),
                ])
              ),
              // The TEXT parts only. See `MultipartBodies` for why the file is not in it.
              ("example", form.example),
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
  /// was recorded, and the routes this server added have no recording at all, so without
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
                (
                  "schema",
                  RequestBodies.schema(
                    for: declared, validation: Self.validation(entry, .body))
                ),
                // `example` and `examples` are mutually exclusive on a media type, so a
                // body with one sample keeps emitting the singular form: the common case,
                // and the reason every other route's output is byte-identical to before
                // named samples existed.
                (
                  "example",
                  declared.examples.count == 1 ? declared.example : nil
                ),
                (
                  "examples",
                  declared.examples.count == 1
                    ? nil
                    : .object(
                      declared.examples.map {
                        (
                          key: $0.name,
                          value: .obj([
                            ("summary", .string($0.summary)),
                            ("description", $0.description.map(OrderedJSON.string)),
                            ("value", $0.value),
                          ])
                        )
                      })
                ),
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
}
