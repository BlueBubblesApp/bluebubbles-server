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
  private func propertyNames(of schema: OrderedJSON) -> Set<String> {
    guard case .object(let members) = schema,
      case .object(let properties)? = members.first(where: { $0.key == "properties" })?.value
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
        #expect(
          body.properties.contains { $0.isRequired },
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
    // would actually accept — not a stale field name, and not missing a required one.
    for (handler, body) in RequestBodies.byHandler {
      guard case .object(let members) = body.example else {
        Issue.record("\(handler.rawValue)'s example is not a JSON object")
        continue
      }
      let declared = Set(body.properties.map(\.name))
      let used = Set(members.map(\.key))
      for key in used.subtracting(declared) {
        Issue.record("\(handler.rawValue)'s example sends undeclared `\(key)`")
      }
      for property in body.properties where property.isRequired {
        #expect(
          used.contains(property.name),
          "\(handler.rawValue)'s example omits required `\(property.name)`")
      }
    }
  }

  @Test("No example sends something the server would refuse")
  func examplesAreNotRefused() {
    // The documented example for `POST message/app` used the POLLS bundle id, which is the
    // one balloon that route refuses — so the spec was telling clients to make the exact
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
  }

  @Test("Every v2 write route has a documented body")
  func v2WriteRoutesAreDocumented() throws {
    // The point of the exercise. A v2 route with no fixture and no declaration reaches the
    // document as a path a client cannot call.
    for entry in RouteCatalog.routes
    where entry.path.hasPrefix("/api/v2/") && entry.route.method != .get {
      let hasBody =
        RequestBodies.byHandler[entry.route.handlerID] != nil
        || MultipartBodies.byHandler[entry.route.handlerID] != nil
        || RequestBodies.bodyless[entry.route.handlerID] != nil
        || FixtureSchemas.table[OpenAPIDocument.operationID(for: entry)]?.request != nil
      let route = "\(entry.route.method.rawValue) \(entry.path)"
      #expect(hasBody, "\(route) neither documents a request body nor declares itself bodyless")
    }
  }
}
