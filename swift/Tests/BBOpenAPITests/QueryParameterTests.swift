//  QueryParameterTests
//  The query string is documented, and documented truthfully.
//
//  It could not be inferred. Handlers read `request.queryParameters` by string, so there is
//  no type to reflect on; the route table does not record them; and the recorder hashes query
//  KEYS into a filename rather than storing them per operation, so a corpus proves a
//  parameter was used once and nothing about what it means. The table is therefore
//  hand-written, and a hand-written table is exactly the kind that rots — it can name a
//  handler that no longer exists, or claim a default the code does not use.

import BBHTTPAPI
import Testing

@testable import BBOpenAPI

@Suite("Query parameters")
struct QueryParameterTests {

  @Test("Every documented handler is a handler that exists")
  func handlersExist() {
    // A renamed handler would otherwise leave its parameters documented against nothing, and
    // the operation that inherited the name silently undocumented.
    let known = Set(RouteCatalog.routes.map(\.route.handlerID))
    for handler in QueryParameters.byHandler.keys {
      #expect(known.contains(handler), "\(handler.rawValue) is documented but unrouted")
    }
  }

  @Test("No parameter is nameless or undescribed")
  func parametersAreDescribed() {
    for (handler, parameters) in QueryParameters.byHandler {
      for parameter in parameters {
        #expect(!parameter.name.isEmpty, "\(handler.rawValue) has an unnamed parameter")
        #expect(
          parameter.description.count > 10,
          "\(handler.rawValue).\(parameter.name) has no useful description")
      }
    }
  }

  @Test("Names are unique within a handler")
  func namesAreUnique() {
    // Two entries with the same name render as two rows for one parameter.
    for (handler, parameters) in QueryParameters.byHandler {
      let names = parameters.map(\.name)
      #expect(Set(names).count == names.count, "\(handler.rawValue) repeats a parameter")
    }
  }

  @Test("A declared default parses as the type it claims")
  func defaultsMatchTheirType() {
    // JSON Schema requires `default` to be an instance of its schema, and a validator
    // enforces it: `'100' is not of type 'integer'`. The table stores defaults as strings,
    // so the conversion has to succeed for every one of them.
    for (handler, parameters) in QueryParameters.byHandler {
      for parameter in parameters {
        guard let fallback = parameter.defaultValue else { continue }
        let context = "\(handler.rawValue).\(parameter.name)"
        switch parameter.type {
        case "integer": #expect(Int(fallback) != nil, "\(context) default is not an integer")
        case "number": #expect(Double(fallback) != nil, "\(context) default is not a number")
        case "boolean":
          #expect(["true", "false"].contains(fallback), "\(context) default is not a boolean")
        default: break
        }
      }
    }
  }

  @Test("An enumerated parameter's default is one of its options")
  func defaultsAreAllowed() {
    for (handler, parameters) in QueryParameters.byHandler {
      for parameter in parameters {
        guard let allowed = parameter.allowed, let fallback = parameter.defaultValue else {
          continue
        }
        #expect(
          allowed.contains(fallback),
          "\(handler.rawValue).\(parameter.name) defaults to \(fallback), which it rejects")
      }
    }
  }

  @Test("Documented parameters reach the emitted document")
  func parametersAreEmitted() throws {
    // End to end: the table is only worth keeping if it lands in the file Scalar reads.
    let document = try OpenAPIDocument.generate().serialized()
    #expect(document.contains("\"name\": \"limit\""))
    #expect(document.contains("\"name\": \"offset\""))
    #expect(document.contains("\"in\": \"query\""))
  }

  @Test("Every multipart handler is a handler that exists")
  func multipartHandlersExist() {
    let known = Set(RouteCatalog.routes.map(\.route.handlerID))
    for handler in MultipartBodies.byHandler.keys {
      #expect(known.contains(handler), "\(handler.rawValue) is documented but unrouted")
    }
  }

  @Test("Every multipart form carries exactly one file field")
  func multipartHasOneFile() {
    // Each of these routes uploads one thing. Two binary fields would mean the description
    // had drifted from a handler that reads a single `files?[...]`.
    for (handler, fields) in MultipartBodies.byHandler {
      let binary = fields.filter { $0.kind == "binary" }
      #expect(binary.count == 1, "\(handler.rawValue) declares \(binary.count) file fields")
      #expect(binary.first?.isRequired == true, "\(handler.rawValue)'s file is not required")
    }
  }

  @Test("Multipart fields are named, typed and described")
  func multipartFieldsAreSound() {
    for (handler, fields) in MultipartBodies.byHandler {
      #expect(Set(fields.map(\.name)).count == fields.count, "\(handler.rawValue) repeats a field")
      for field in fields {
        #expect(["string", "binary"].contains(field.kind), "\(field.name) has kind \(field.kind)")
        #expect(field.description.count > 10, "\(handler.rawValue).\(field.name) is undescribed")
      }
    }
  }

  @Test("A multipart route does not also claim a JSON body")
  func multipartWins() throws {
    // The two sources would otherwise both fire and the JSON one — inferred from a body the
    // recorder stored as raw text — would be nonsense.
    let document = try OpenAPIDocument.generate()
    guard case .object(let root) = document,
      case .object(let paths)? = root.first(where: { $0.key == "paths" })?.value
    else { return }
    for (_, item) in paths {
      guard case .object(let methods) = item else { continue }
      for (_, op) in methods {
        guard case .object(let fields) = op,
          case .object(let body)? = fields.first(where: { $0.key == "requestBody" })?.value,
          case .object(let content)? = body.first(where: { $0.key == "content" })?.value
        else { continue }
        let types = content.map(\.key)
        #expect(types.count == 1, "an operation declares \(types) together")
      }
    }
  }

  @Test("Binary routes describe bytes, not the envelope")
  func binaryRoutesAreNotJSON() throws {
    // A generated client would otherwise try to JSON-decode a JPEG.
    let document = try OpenAPIDocument.generate()
    guard case .object(let root) = document,
      case .object(let paths)? = root.first(where: { $0.key == "paths" })?.value
    else { return }

    var checked = 0
    for (_, item) in paths {
      guard case .object(let methods) = item else { continue }
      for (_, op) in methods {
        guard case .object(let fields) = op,
          case .string(let handler)? = fields.first(where: { $0.key == "x-handler-id" })?.value,
          NonJSONResponses.binary[HandlerID(handler)] != nil,
          case .object(let responses)? = fields.first(where: { $0.key == "responses" })?.value,
          case .object(let ok)? = responses.first(where: { $0.key == "200" })?.value,
          case .object(let content)? = ok.first(where: { $0.key == "content" })?.value
        else { continue }
        checked += 1
        #expect(!content.contains { $0.key == "application/json" }, "\(handler) claims JSON")
      }
    }
    #expect(checked > 0, "no binary routes reached the document")
  }

  @Test("The one 201 route says 201 and nothing says 200 for it")
  func alternateSuccessIsHonest() throws {
    // `facetime.leave` returns `.noData`, which the router answers as 201. Documenting 200
    // makes a strict client treat a correct response as a failure.
    let document = try OpenAPIDocument.generate()
    guard case .object(let root) = document,
      case .object(let paths)? = root.first(where: { $0.key == "paths" })?.value
    else { return }

    var found = false
    for (_, item) in paths {
      guard case .object(let methods) = item else { continue }
      for (_, op) in methods {
        guard case .object(let fields) = op,
          case .string(let handler)? = fields.first(where: { $0.key == "x-handler-id" })?.value,
          let alternate = NonJSONResponses.alternateSuccess[HandlerID(handler)],
          case .object(let responses)? = fields.first(where: { $0.key == "responses" })?.value
        else { continue }
        found = true
        let codes = responses.map(\.key)
        #expect(codes.contains(String(alternate.status)), "\(handler) omits its real status")
        #expect(!codes.contains("200"), "\(handler) still claims 200")
      }
    }
    #expect(found, "the 201 route never reached the document")
  }

  @Test("Every non-JSON handler is a handler that exists")
  func nonJSONHandlersExist() {
    let known = Set(RouteCatalog.routes.map(\.route.handlerID))
    for handler in NonJSONResponses.binary.keys {
      #expect(known.contains(handler), "\(handler.rawValue) is documented but unrouted")
    }
    for handler in NonJSONResponses.alternateSuccess.keys {
      #expect(known.contains(handler), "\(handler.rawValue) is documented but unrouted")
    }
  }
}
