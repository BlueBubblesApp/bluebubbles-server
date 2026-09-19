//  V2ParameterParityTests
//  Every v2 input the API document promises is read by the handler that serves it.
//
//  `RequestParameterParityTests` cannot cover v2: it diffs against the Node routers, and v2
//  is the half of this server that has no counterpart there. That left the whole additive
//  surface — polls, Send Later, stickers, app balloons, FindMy, chat controls — with nothing
//  asking the question that found `where`, `addresses`, `extraProperties` and the rest:
//  "this route is handed a parameter and no line of the handler mentions it".
//
//  The second source is the OpenAPI document rather than a list written here, and that is
//  what keeps this from being a tautology. `Sources/BBOpenAPI/RequestBodies.swift` and
//  `MultipartBodies.swift` are hand-written declarations of what each v2 route ACCEPTS,
//  authored for client authors and checked into `docs/api/openapi.json`; the handlers are
//  written separately. A field that appears in one and not the other is a promise to
//  clients that nothing keeps — which is exactly what "accepted and ignored" looks like
//  from outside.
//
//  Failing here means one of two things, and both are worth a person's attention: the
//  handler stopped reading something the document offers, or the document offers something
//  that was never built.

import BBHTTPAPI
import BBOpenAPI
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("v2 request parameter parity")
struct V2ParameterParityTests {

  /// Inputs that are not the handler's to read, with the reason.
  ///
  /// Each is read by a layer the scan does not scope to, or is not a field at all. An entry
  /// is a decision, the same as its v1 counterpart: the name has to be explained, not just
  /// absent.
  static let readElsewhere: Set<String> = [
    // Middleware, not a handler input.
    "password", "guid", "id",
    // Relation lists. Every route spells them differently and the names are asserted where
    // they are parsed (`ChatInterface.Query.parse`, `MessageInterface.Query.parse`).
    "with",
    // The multipart file part itself, read by `UploadedFileBody` rather than by name.
    "attachment", "icon", "chunk",
  ]

  /// What the API document says each v2 operation accepts.
  ///
  /// Query parameters and top-level request-body properties, keyed the way the route table
  /// spells a route, so the two can be joined.
  static let documented: [String: Set<String>] = {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("docs/api/openapi.json")
    guard let data = try? Data(contentsOf: url),
      let document = try? JSONValue.parse(data),
      case .object(let paths)? = document["paths"]
    else { return [:] }

    var result: [String: Set<String>] = [:]
    for (path, operations) in paths where path.hasPrefix("/api/v2/") {
      guard case .object(let byMethod) = operations else { continue }
      for (method, operation) in byMethod {
        guard ["get", "post", "put", "delete"].contains(method) else { continue }
        var names: Set<String> = []
        for parameter in operation["parameters"]?.arrayValue ?? []
        where
          parameter["in"]?.stringValue == "query"
        {
          if let name = parameter["name"]?.stringValue { names.insert(name) }
        }
        for (_, media) in (operation["requestBody"]?["content"]).flatMap({
          value -> [String: JSONValue]? in
          guard case .object(let object) = value else { return nil }
          return object
        }) ?? [:] {
          names.formUnion(media["schema"]?["properties"]?.objectKeys ?? [])
        }
        names.subtract(readElsewhere)
        guard !names.isEmpty else { continue }
        // `{guid}` in the document, `:guid` in the route table: one spelling, normalised
        // here rather than in both places.
        let normalised = path.replacing(/\{(\w+)\}/) { ":\($0.output.1)" }
        result["\(method.uppercased()) \(normalised)"] = names
      }
    }
    return result
  }()

  /// Route to the source of the file that registers its handler, the same two hops the v1
  /// suite makes: a route table entry carries a `HandlerID`, `HandlerIDs.swift` relates the
  /// raw id to the Swift property, and a file registers that property.
  static let handlerSources: [String: String] = {
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources")

    var propertyForID: [String: String] = [:]
    let ids =
      (try? String(
        contentsOf: sources.appendingPathComponent("BBHTTPAPI/HandlerIDs.swift"),
        encoding: .utf8)) ?? ""
    for line in ids.split(separator: "\n") {
      guard let name = line.firstMatch(of: /static let (\w+) = HandlerID\("([^"]+)"\)/) else {
        continue
      }
      propertyForID[String(name.2)] = String(name.1)
    }

    var byProperty: [String: String] = [:]
    let handlers = sources.appendingPathComponent("BBHandlers")
    if let walker = FileManager.default.enumerator(at: handlers, includingPropertiesForKeys: nil) {
      for case let url as URL in walker where url.pathExtension == "swift" {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for match in text.matches(of: /registry\.register\(\.(\w+)\)/) {
          byProperty[String(match.1), default: ""] += text
        }
        for match in text.matches(of: /\(\.(\w+),/) {
          byProperty[String(match.1), default: ""] += text
        }
      }
    }

    // `RouteCatalog.all` rather than `RouteTable.groups`: the v2 surface is the ADDITIVE
    // groups, which `groups` does not contain — it is the Node table and nothing else.
    var result: [String: String] = [:]
    for entry in RouteCatalog.all where entry.group.apiVersion == 2 {
      for route in entry.group.routes {
        let path = RouteTable.path(of: route, in: entry.group)
        guard let property = propertyForID[route.handlerID.rawValue],
          let source = byProperty[property]
        else { continue }
        result["\(route.method.rawValue) \(path)"] = source
      }
    }
    return result
  }()

  /// The floor: a scan that resolves nothing passes everything.
  @Test("The v2 surface is found, and its handlers resolve")
  func scanIsReadingSomething() {
    #expect(
      Self.documented.count >= 25,
      "the document gave \(Self.documented.count) v2 operations with inputs")
    let unresolved = Self.documented.keys.filter { Self.handlerSources[$0] == nil }.sorted()
    #expect(
      unresolved.isEmpty,
      Comment(
        rawValue: "these documented v2 routes resolve to no handler file:\n  "
          + unresolved.joined(separator: "\n  ")))
  }

  @Test("Every documented v2 input is named by the handler that serves it")
  func everyDocumentedInputIsRead() {
    var missing: [String] = []
    for (route, names) in Self.documented.sorted(by: { $0.key < $1.key }) {
      guard let source = Self.handlerSources[route] else { continue }
      for name in names.sorted() where !source.contains("\"\(name)\"") {
        missing.append("\(route) → \(name)")
      }
    }
    #expect(
      missing.isEmpty,
      Comment(
        rawValue: """
          These v2 inputs are promised by docs/api/openapi.json and named nowhere in the \
          handler that serves the route, so nothing on that route can be reading them:
            \(missing.joined(separator: "\n  "))
          Either the handler stopped reading it, or the document offers something that was \
          never built. Both need deciding rather than silencing.
          """))
  }
}
