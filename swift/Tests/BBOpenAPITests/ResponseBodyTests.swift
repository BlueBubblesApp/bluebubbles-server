//  ResponseBodyTests
//  The declared responses are complete, and never contradict a recorded one.
//
//  `ResponseBodies` is hand-written, so it rots: it can name a handler that no longer
//  routes, describe a field the serializer stopped emitting, or — worst — grow a
//  declaration for a route that has since been recorded, leaving two accounts of the same
//  response with the unverified one visible. These make each of those a build failure.

import BBHTTPAPI
import Testing

@testable import BBOpenAPI

@Suite("Response bodies")
struct ResponseBodyTests {

  @Test("Every declared response is a handler that exists")
  func handlersExist() {
    let known = Set(RouteCatalog.routes.map(\.route.handlerID))
    for handler in ResponseBodies.byHandler.keys {
      #expect(known.contains(handler), "\(handler.rawValue) is documented but unrouted")
    }
  }

  @Test("A declaration never competes with a recorded response")
  func declarationsFillOnlyGaps() {
    // The rule that makes this table safe. A fixture is evidence; this is testimony, and
    // testimony does not get to overrule evidence. If a route here is ever recorded, the
    // declaration must be deleted rather than left to disagree in silence.
    for entry in RouteCatalog.routes
    where ResponseBodies.byHandler[entry.route.handlerID] != nil {
      let recorded = FixtureSchemas.table[OpenAPIDocument.operationID(for: entry)]?.response
      let name = entry.route.handlerID.rawValue
      #expect(
        recorded == nil,
        "\(name) has a recorded response AND a declaration — delete the declaration")
    }
  }

  @Test("A declared response is not also declared binary")
  func jsonAndBinaryAreExclusive() {
    // `sticker.image` answers with bytes and is declared in `NonJSONResponses`. A handler
    // in both tables would document a JSON payload for a route that never sends one.
    for handler in ResponseBodies.byHandler.keys {
      #expect(
        NonJSONResponses.binary[handler] == nil,
        "\(handler.rawValue) declares both a JSON and a binary response")
    }
  }

  @Test("Every field is named, described and required-marked")
  func fieldsAreSound() {
    for (handler, body) in ResponseBodies.byHandler {
      #expect(body.summary.count > 10, "\(handler.rawValue) has no useful summary")
      #expect(!body.properties.isEmpty, "\(handler.rawValue) declares an empty response")
      #expect(
        Set(body.properties.map(\.name)).count == body.properties.count,
        "\(handler.rawValue) repeats a field")
      for property in body.properties {
        #expect(!property.name.isEmpty, "\(handler.rawValue) has an unnamed field")
        #expect(
          property.description.count > 10,
          "\(handler.rawValue).\(property.name) has no useful description")
      }
    }
  }

  @Test("Every example matches the shape it is an example of")
  func examplesMatchTheirShape() {
    // The example is what a client author copies, so an array route's example has to be an
    // array and an object route's an object — and the object's keys have to be fields this
    // response actually declares.
    for (handler, body) in ResponseBodies.byHandler {
      let object: OrderedJSON?
      if body.isArray {
        guard case .array(let elements) = body.example else {
          Issue.record("\(handler.rawValue) is an array response with a non-array example")
          continue
        }
        #expect(!elements.isEmpty, "\(handler.rawValue)'s example array is empty")
        object = elements.first
      } else {
        object = body.example
      }
      guard case .object(let members)? = object else {
        Issue.record("\(handler.rawValue)'s example is not a JSON object")
        continue
      }
      let declared = Set(body.properties.map(\.name))
      for key in Set(members.map(\.key)).subtracting(declared) {
        Issue.record("\(handler.rawValue)'s example carries undeclared `\(key)`")
      }
      // A required field missing from the example would teach a client it is optional.
      for property in body.properties where property.isRequired {
        #expect(
          members.contains { $0.key == property.name },
          "\(handler.rawValue)'s example omits required `\(property.name)`")
      }
    }
  }

  @Test("Declared responses reach the emitted document")
  func responsesAreEmitted() throws {
    let document = try OpenAPIDocument.generate().serialized()
    // The field a client cannot work without, and the one most easily lost.
    #expect(document.contains("\"external_uri\""))
    #expect(document.contains("Emoji and Memoji"))
    // The example, with a real identifier from a live Mac in it.
    #expect(document.contains("7608FF1D-006B-4E00-B15A-DDB5001BCBF6"))
  }
}
