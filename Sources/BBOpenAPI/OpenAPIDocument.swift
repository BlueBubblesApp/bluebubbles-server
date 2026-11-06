//  OpenAPIDocument
//  The generated OpenAPI 3.1 description of the HTTP surface.
//
//  Derived from `RouteCatalog`, which is derived from the same `RouteTable` that builds the
//  router, so the document cannot describe a route the server does not serve, and adding a
//  route to the table adds it here without anybody remembering to.
//
//  WHAT THIS DOCUMENT DOES NOT KNOW, and deliberately does not guess:
//
//    - Request and response BODY SCHEMAS. The route table has no types to reflect: handlers
//      take an `APIRequestContext` and return an untyped `JSONValue`, so there is nothing to
//      derive a schema FROM. Every operation therefore describes the envelope and leaves
//      `data` unconstrained. Filling those in is a separate job with its own source of truth
//      (the recorded fixtures); see `FixtureCoverage`.
//
//  Two things are declared beside the table rather than inferred, because neither could ever
//  come from a recording:
//    - QUERY PARAMETERS: `QueryParameters`, keyed by handler.
//    - MULTIPART BODIES and NON-JSON RESPONSES: `MultipartBodies` and `NonJSONResponses`.
//      The latter also carries the one route whose success is 201 rather than 200, derived
//      from the handler returning `.noData` rather than special-cased by path.
//
//  Each of those is a gap a hand-written spec would paper over with a guess. An emitted
//  document that states only what the table actually knows is worth more than one that reads
//  complete and is quietly wrong in nine places.
//
//  The document is emitted in parts: `OpenAPIDocument+Info.swift`,
//  `OpenAPIDocument+Operations.swift`, `OpenAPIDocument+Responses.swift` and
//  `OpenAPIDocument+Components.swift`. This file holds the options, the entry point and the
//  path and identifier derivation every part relies on.
//
//  See `.claude/docs/api.md`.

import BBAuth
import BBHTTPAPI
import BBLicense
import BBSerialization
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
          + "operationId must be unique; fix `operationID(for:)`."
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
  /// unique: `POST :guid/participant` and `POST :guid/participant/add` deliberately share
  /// `chat.addParticipant`, and `PUT /contact` and `PUT /contact/:id` share `contact.update`.
  /// The version stays in the identifier because v1 and v2 both serve `GET /server/alert`.
  /// The recorded `data` schema of another handler, for a mirrored declaration.
  ///
  /// Nil when that handler has no recording, which `ResponseBodyTests` forbids, so a
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
  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func summary(for entry: RouteCatalog.Entry) -> String {
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

  /// Shared with the `OpenAPIDocument+*.swift` parts.
  static func seconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds)
  }
}
