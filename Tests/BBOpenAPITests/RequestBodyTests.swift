//  RequestBodyTests
//  The declared request bodies are complete, and cannot regress an inferred one.
//
//  `RequestBodies` is hand-written, so it rots the way every hand-written table rots: it can
//  name a handler that no longer routes, describe a field the handler stopped reading, or
//  carry an example that no longer parses as the body it claims to be. Worse, a declaration
//  SUPERSEDES an inferred schema, so a careless one could hide a field that was really
//  recorded against the reference server. These tests make each of those a build failure.

import BBHTTPAPI
import Testing

@testable import BBOpenAPI

@Suite("Request bodies")
struct RequestBodyTests {

  /// The property names at the top level of an OpenAPI object schema.
  ///
  /// An ARRAY schema is unwrapped to its `items` first, so the superset check still bites on
  /// the three contact routes, whose recorded bodies are arrays. Without that it compared an
  /// object's properties against nothing and passed for any declaration at all.
  private func propertyNames(of schema: OrderedJSON) -> Set<String> {
    guard case .object(let members) = schema else { return [] }
    if let items = members.first(where: { $0.key == "items" })?.value {
      return propertyNames(of: items)
    }
    guard case .object(let properties)? = members.first(where: { $0.key == "properties" })?.value
    else { return [] }
    return Set(properties.map(\.key))
  }

  @Test("Every declared body is a handler that exists")
  func handlersExist() {
    let known = Set(RouteCatalog.routes.map(\.route.handlerID))
    for handler in RequestBodies.byHandler.keys {
      #expect(known.contains(handler), "\(handler.rawValue) is documented but unrouted")
    }
  }

  @Test("Only routes that take a body declare one")
  func bodiesAreOnWriteRoutes() {
    // A GET with a documented body would tell a client to send something the router drops.
    for entry in RouteCatalog.routes where RequestBodies.byHandler[entry.route.handlerID] != nil {
      #expect(
        entry.route.method != .get,
        "\(entry.route.handlerID.rawValue) is a GET with a declared request body")
    }
  }

  @Test("Every property is named, described and reachable")
  func propertiesAreSound() {
    for (handler, body) in RequestBodies.byHandler {
      #expect(body.summary.count > 10, "\(handler.rawValue) has no useful summary")
      #expect(
        Set(body.properties.map(\.name)).count == body.properties.count,
        "\(handler.rawValue) repeats a property")
      #expect(!body.properties.isEmpty, "\(handler.rawValue) declares a body with no fields")
      if body.isRequired {
        // A BATCH is exempt, and the exemption is about what "required" can express rather
        // than about letting one through. Its requirement is "at least one entry", which no
        // property name states, and its entries are satisfied by a CHOICE of fields: a
        // contact needs one of `firstName`, `lastName` or `displayName` and one of
        // `phoneNumbers` or `emails`, so naming any single one required would document a
        // refusal this server does not make.
        #expect(
          body.isBatch || body.properties.contains { $0.isRequired },
          "\(handler.rawValue) demands a body but requires nothing in it")
      } else {
        #expect(
          !body.properties.contains { $0.isRequired },
          "\(handler.rawValue) has a required field in an optional body")
      }
      for property in body.properties {
        #expect(!property.name.isEmpty, "\(handler.rawValue) has an unnamed property")
        #expect(
          property.description.count > 10,
          "\(handler.rawValue).\(property.name) has no useful description")
      }
    }
  }

  @Test("Every example is an object of declared properties")
  func examplesAreConsistent() {
    // The example is the part a client author copies, so it has to be a body this route
    // would actually accept, not a stale field name, and not missing a required one.
    //
    // EVERY example, not the first: a body may carry several named samples, and a stale
    // field name in the fourth one is exactly as wrong as in the first. Checking only
    // `body.example` would have left four of `POST message/query`'s five unchecked.
    for (handler, body) in RequestBodies.byHandler {
      let declared = Set(body.properties.map(\.name))
      for example in body.examples {
        let label = "\(handler.rawValue)'s `\(example.name)` example"
        // A batch body's sample is an ARRAY, and every entry in it is checked: a stale field
        // name in the second contact of a two-contact sample is exactly as wrong as in the
        // first, and checking only the first is how the array shape would buy less than it
        // costs.
        let entries: [OrderedJSON]
        if body.isBatch {
          guard case .array(let elements) = example.value, !elements.isEmpty else {
            Issue.record("\(label) is a batch body and its sample is not a non-empty array")
            continue
          }
          entries = elements
        } else {
          entries = [example.value]
        }
        for entry in entries {
          guard case .object(let members) = entry else {
            Issue.record("\(label) is not a JSON object")
            continue
          }
          let used = Set(members.map(\.key))
          for key in used.subtracting(declared) {
            Issue.record("\(label) sends undeclared `\(key)`")
          }
          for property in body.properties where property.isRequired {
            #expect(used.contains(property.name), "\(label) omits required `\(property.name)`")
          }
        }
      }
    }
  }

  @Test("Named examples are named, summarised and distinct")
  func namedExamplesAreSound() {
    // The names are OpenAPI `examples` keys, so a duplicate silently loses a sample and an
    // empty one produces a key a viewer cannot render. `Body.example` reads `examples[0]`,
    // so an empty list is a crash rather than a missing example.
    for (handler, body) in RequestBodies.byHandler {
      #expect(!body.examples.isEmpty, "\(handler.rawValue) declares no example")
      #expect(
        Set(body.examples.map(\.name)).count == body.examples.count,
        "\(handler.rawValue) repeats an example name")
      for example in body.examples {
        #expect(!example.name.isEmpty, "\(handler.rawValue) has an unnamed example")
        #expect(
          example.summary.count > 10,
          "\(handler.rawValue)'s `\(example.name)` example has no useful summary")
        if let description = example.description {
          #expect(
            description.count > 20,
            "\(handler.rawValue)'s `\(example.name)` example has a description that says nothing")
        }
      }

      // A summary is a picker LABEL only where a picker is rendered, which is a body with
      // more than one sample. The single-sample wrapper reuses the body's own summary and
      // is emitted as a bare `example`, so nothing displays it and prose is fine there.
      guard body.examples.count > 1 else { continue }
      for example in body.examples {
        #expect(
          example.summary.count <= RequestBodies.Example.maximumSummaryLength,
          """
          \(handler.rawValue)'s `\(example.name)` summary is \(example.summary.count)           characters; a viewer truncates the picker's label past           \(RequestBodies.Example.maximumSummaryLength). Put the reasoning in its description.
          """)
        #expect(
          example.description != nil,
          "\(handler.rawValue)'s `\(example.name)` example has a label but no description")
      }
    }
  }

  @Test("A multi-sample body emits `examples`, and a single one still emits `example`")
  func exampleSingularAndPlural() throws {
    // The two are mutually exclusive on an OpenAPI media type, so this is well-formedness
    // rather than taste. It also pins the byte-for-byte output of every single-sample body,
    // which is what stops named samples from rewriting the whole committed document.
    let document = try OpenAPIDocument.generate()
    guard
      case .object(let paths)? = member("paths", of: document),
      case .object(let query)? = paths.first(where: { $0.key == "/api/v1/message/query" })?.value,
      case .object(let post)? = query.first(where: { $0.key == "post" })?.value,
      let requestBody = post.first(where: { $0.key == "requestBody" })?.value,
      let content = member("content", of: requestBody),
      case .object(let json)? = member("application/json", of: content)
    else {
      Issue.record("POST /api/v1/message/query has no JSON request body")
      return
    }
    #expect(json.contains { $0.key == "examples" })
    #expect(!json.contains { $0.key == "example" })

    // And the single-sample path is untouched.
    let serialized = document.serialized()
    #expect(serialized.contains("\"example\": {"))
  }

  /// One member of an `OrderedJSON` object, by key.
  private func member(_ key: String, of value: OrderedJSON) -> OrderedJSON? {
    guard case .object(let members) = value else { return nil }
    return members.first { $0.key == key }?.value
  }

  @Test("No example sends something the server would refuse")
  func examplesAreNotRefused() {
    // The documented example for `POST message/app` used the POLLS bundle id, which is the
    // one balloon that route refuses, so the spec was telling clients to make the exact
    // request that had already put two broken balloons in a real conversation. An example
    // the server rejects is worse than no example, and vigilance is not a mechanism.
    guard case .object(let members)? = RequestBodies.byHandler[.messageSendApp]?.example,
      let bundle = members.first(where: { $0.key == "balloonBundleId" })?.value,
      case .string(let identifier) = bundle
    else {
      Issue.record("the app-message example declares no balloonBundleId")
      return
    }
    #expect(
      !identifier.hasSuffix("com.apple.messages.Polls"),
      "the app-message example sends the Polls balloon, which that route refuses")
  }

  @Test("A declaration never drops an inferred property")
  func declarationsAreSupersets() {
    // The one real hazard of letting a declaration win. A field recorded against the
    // reference server is proof the field is accepted, so a declaration may only add.
    for entry in RouteCatalog.routes {
      guard let declared = RequestBodies.byHandler[entry.route.handlerID],
        let inferred = FixtureSchemas.table[OpenAPIDocument.operationID(for: entry)]?.request
      else { continue }
      let missing = propertyNames(of: inferred).subtracting(declared.properties.map(\.name))
      let dropped = missing.sorted().joined(separator: ", ")
      #expect(
        missing.isEmpty,
        "\(entry.route.handlerID.rawValue) declares a body that drops recorded \(dropped)")
    }
  }

  @Test("The bodyless list is real routes, with reasons, and no double claim")
  func bodylessIsSound() {
    let known = Set(RouteCatalog.routes.map(\.route.handlerID))
    for (handler, reason) in RequestBodies.bodyless {
      #expect(known.contains(handler), "\(handler.rawValue) is declared bodyless but unrouted")
      #expect(reason.count > 10, "\(handler.rawValue) is bodyless for no stated reason")
      #expect(
        RequestBodies.byHandler[handler] == nil,
        "\(handler.rawValue) is declared both bodyless and with a body")
    }
    // A route the reference really did take a body on is not bodyless, whatever this says.
    for entry in RouteCatalog.routes where RequestBodies.bodyless[entry.route.handlerID] != nil {
      #expect(
        FixtureSchemas.table[OpenAPIDocument.operationID(for: entry)]?.request == nil,
        "\(entry.route.handlerID.rawValue) is declared bodyless but a fixture recorded a body")
    }
  }

  @Test("Multipart still wins over a declaration")
  func multipartWins() {
    // Both tables are hand-written, so nothing but this stops a route from being described
    // twice, in two content types, with the JSON one losing the file.
    for handler in RequestBodies.byHandler.keys {
      #expect(
        MultipartBodies.byHandler[handler] == nil,
        "\(handler.rawValue) declares both a multipart and a JSON body")
    }
  }

  @Test("Declared bodies reach the emitted document with their examples")
  func bodiesAreEmitted() throws {
    // End to end: the table is only worth keeping if it lands in the file Scalar reads.
    let document = try OpenAPIDocument.generate().serialized()
    #expect(document.contains("Casts this account's vote"))
    #expect(document.contains("\"optionIds\""))
    #expect(document.contains("\"example\""))
    #expect(document.contains("Game Pigeon's own payload version"))
    // `POST message/query`, whose samples are the reason named examples exist: the `where`
    // allowlist and the `with` relations both reach the file a reader opens.
    #expect(document.contains("message.ROWID <= :endRowId"))
    #expect(document.contains("message.associated_message_guid IS NULL"))
    #expect(document.contains("message.guid IN (:...guids)"))
    #expect(document.contains("chat.participants"))
  }

  @Test("Every write route has a documented body, or says it has none")
  func writeRoutesAreDocumented() throws {
    // The point of the exercise, and it covers v1 as well as v2 now that every body carries
    // a sample. A route in neither table reaches the document as a path a client author can
    // see and cannot call: no fields, no sample, and no statement that there is nothing to
    // send. All three of those absences look the same from the outside.
    for entry in RouteCatalog.routes where entry.route.method != .get {
      let hasBody =
        RequestBodies.byHandler[entry.route.handlerID] != nil
        || MultipartBodies.byHandler[entry.route.handlerID] != nil
        || RequestBodies.bodyless[entry.route.handlerID] != nil
        || FixtureSchemas.table[OpenAPIDocument.operationID(for: entry)]?.request != nil
      let route = "\(entry.route.method.rawValue) \(entry.path)"
      #expect(hasBody, "\(route) neither documents a request body nor declares itself bodyless")
    }
  }

  @Test("A bodyless route says so in the document")
  func bodylessRoutesSaySo() throws {
    // The table is only worth writing if the sentence reaches the reader. It is emitted into
    // the operation's description, which is the one place a viewer shows when there is no
    // request body to render.
    let document = try OpenAPIDocument.generate().serialized()
    #expect(document.contains("Takes no request body. The conversation is the path"))
    #expect(document.contains("Takes no request body. The call is `:call_uuid` in the path."))
  }
}
