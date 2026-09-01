//  OpenAPIDocumentTests
//  What has to stay true about the generated document as the route table grows.
//
//  These assert PROPERTIES, not the document's contents. Pinning the output verbatim would
//  make every route addition fail a test that then gets re-baselined without being read,
//  which is a check that costs work and catches nothing. The committed document plus
//  `bb-openapi emit --check` already covers "did the output change"; what needs asserting
//  here is that the output stays VALID as it changes.

import BBHTTPAPI
import Testing

@testable import BBOpenAPI

@Suite("OpenAPI document")
struct OpenAPIDocumentTests {

  @Test("Operation IDs are unique across every route")
  func operationIDsAreUnique() throws {
    // The reason this is not obviously true: handler IDs are deliberately NOT unique, so
    // the naive derivation collides on `chat.addParticipant` and `contact.update`. And v1
    // and v2 both serve `GET /server/alert`, so dropping the version collides too.
    var seen: [String: String] = [:]
    for entry in RouteCatalog.routes {
      let id = OpenAPIDocument.operationID(for: entry)
      let signature = "\(entry.route.method.rawValue) \(entry.path)"
      #expect(seen[id] == nil, "operationId '\(id)': \(seen[id] ?? "") and \(signature)")
      seen[id] = signature
    }
  }

  @Test("Generation succeeds for the whole catalog")
  func generatesWithoutThrowing() throws {
    _ = try OpenAPIDocument.generate()
  }

  @Test("Every tag an operation references is declared, and every parent exists")
  func tagHierarchyIsWellFormed() throws {
    // 3.2 requires a `parent` to name a tag that exists in the document. Nothing enforces
    // that at generation time, and a viewer given a dangling parent either drops the section
    // or renders it detached — visible only by opening the rendered page, which nobody does
    // on a routine change.
    let document = try OpenAPIDocument.generate()
    guard case .object(let root) = document else {
      Issue.record("document root is not an object")
      return
    }

    var declared: Set<String> = []
    var parents: [String] = []
    if case .array(let tags)? = root.first(where: { $0.key == "tags" })?.value {
      for tag in tags {
        guard case .object(let fields) = tag else { continue }
        if case .string(let name)? = fields.first(where: { $0.key == "name" })?.value {
          declared.insert(name)
        }
        if case .string(let parent)? = fields.first(where: { $0.key == "parent" })?.value {
          parents.append(parent)
        }
      }
    }

    for parent in parents {
      #expect(declared.contains(parent), "tag parent '\(parent)' is not declared")
    }
    #expect(declared.contains("v1"))
    #expect(declared.contains("v2"))
  }

  @Test("Tag names are unique per group and version")
  func tagNamesAreUnique() {
    // The name is an identifier, not a label: `Chat` exists in v1 and v2 and they are
    // different endpoint sets, so a collision would merge two sections in every viewer.
    var byName: [String: String] = [:]
    for entry in RouteCatalog.routes {
      let key = "\(entry.group.name)|v\(entry.group.apiVersion)"
      let slug = entry.group.name
        .lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .joined(separator: "-")
      let name = entry.group.mountsAtRoot ? slug : "\(slug)-v\(entry.group.apiVersion)"
      if let existing = byName[name] {
        #expect(existing == key, "tag name '\(name)' is shared by \(existing) and \(key)")
      }
      byName[name] = key
    }
  }

  @Test("Output is byte-stable across runs")
  func outputIsDeterministic() throws {
    // The whole reason `OrderedJSON` exists. `JSONValue` would fail this: its object case
    // is a Dictionary, so key order varies between runs and the committed document would
    // report a diff for a table nobody touched.
    let first = try OpenAPIDocument.generate().serialized()
    let second = try OpenAPIDocument.generate().serialized()
    #expect(first == second)
  }

  @Test("The document says nothing about how it is built")
  func noBuildProvenanceLeaks() throws {
    // This document is read by API CONSUMERS — `APIDocsView` renders it inside the app, and
    // whatever viewer someone points at the committed file renders it everywhere else. How
    // it is produced is a contributor's concern; `docs/api/README.md` is where that belongs.
    //
    // It leaked twice before this test existed: an `info.description` opening with "**This
    // document is generated** … by `swift run bb-openapi emit`", and a per-schema note that
    // named the recorded corpus, repeated onto 83 schemas. Both read to an outsider as an
    // admission rather than as the useful caveat they were meant to be.
    //
    // Caveats about what a schema GUARANTEES are still wanted and still there — the rule is
    // to say what the reader can rely on, never the machinery that decided it.
    let serialized = try OpenAPIDocument.generate().serialized().lowercased()
    for term in [
      "swift run", "sources/", "bb-openapi", "regenerate", "do not edit",
      "recorded", "recording", "corpus", "fixture", "inferred", "inference",
      "this document is generated",
    ] {
      #expect(
        !serialized.contains(term),
        "the emitted document contains \"\(term)\" — build provenance belongs in docs/api/README.md, not in a published API description"
      )
    }
  }

  @Test("Every path parameter is templated into OpenAPI form")
  func pathParametersAreTemplated() throws {
    for entry in RouteCatalog.routes {
      let templated = OpenAPIDocument.templatize(entry.path).path
      #expect(!templated.contains(":"), "\(entry.path) still carries an Express parameter")
    }
  }

  @Test("Templating reports the parameters it substituted")
  func templatizeReportsParameters() {
    let result = OpenAPIDocument.templatize("/api/v1/chat/:guid/:messageGuid")
    #expect(result.path == "/api/v1/chat/{guid}/{messageGuid}")
    #expect(result.parameters == ["guid", "messageGuid"])
  }

  @Test("Duplicate handler IDs still produce distinct operations")
  func duplicateHandlersAreDistinctOperations() throws {
    // `POST :guid/participant` and `POST :guid/participant/add` share a handler on
    // purpose. Both must appear: a client on the older path needs to find it documented.
    let ids = RouteCatalog.routes
      .filter { $0.route.handlerID.rawValue == "chat.addParticipant" }
      .map { OpenAPIDocument.operationID(for: $0) }
    #expect(ids.count == 2)
    #expect(Set(ids).count == 2)
  }
}

@Suite("Route catalog")
struct RouteCatalogTests {

  @Test("Every additive group reaches the catalog")
  func additiveGroupsAreCatalogued() {
    // The catalog lists the additive groups by hand, because `additiveGroups` turns them
    // on individually behind different switches and there is no list to read. That makes
    // "added a group, forgot the catalog" a silent documentation hole, so it is asserted:
    // every group registered by the composition root must be described here.
    let catalogued = Set(RouteCatalog.all.map { "\($0.group.name)|\($0.group.apiVersion)" })
    let expected = [
      AdditiveRoutes.security, AdditiveRoutes.alerts, AdditiveRoutes.contactAvatar,
      AdditiveRoutes.chatPinning, AdditiveRoutes.webhookEditing,
      AdditiveRoutes.chatControls, AdditiveRoutes.findMy, AdditiveRoutes.findMySharing,
      AdditiveRoutes.faceTime, AdditiveRoutes.faceTimeIncoming, AdditiveRoutes.auth,
      AdditiveRoutes.hydration,
    ]
    for group in expected {
      #expect(
        catalogued.contains("\(group.name)|\(group.apiVersion)"),
        "\(group.name) is registered by the composition root but missing from RouteCatalog"
      )
    }
  }

  @Test("The catalog carries the whole v1 table")
  func v1IsComplete() {
    let catalogued = RouteCatalog.routes.filter {
      $0.availability == .always && !$0.group.mountsAtRoot
    }
    #expect(catalogued.count == RouteTable.mountedRoutes().count)
  }

  @Test("Catalog paths agree with the router's own derivation")
  func pathsMatchRouteTable() {
    for (path, group, route) in RouteTable.mountedRoutes() {
      #expect(RouteTable.path(of: route, in: group) == path)
    }
  }
}

@Suite("Ordered JSON")
struct OrderedJSONTests {

  @Test("Key order is preserved")
  func preservesKeyOrder() {
    let value = OrderedJSON.object([
      (key: "zebra", value: .int(1)),
      (key: "apple", value: .int(2)),
    ])
    // Serialized in insertion order, NOT sorted — a sorted writer would also be stable,
    // but the document reads best in the order the emitter builds it.
    #expect(value.serialized() == "{\n  \"zebra\": 1,\n  \"apple\": 2\n}\n")
  }

  @Test("obj drops nil values")
  func objDropsNil() {
    let value = OrderedJSON.obj([("a", .int(1)), ("b", nil), ("c", .int(3))])
    #expect(value.serialized() == "{\n  \"a\": 1,\n  \"c\": 3\n}\n")
  }

  @Test("Strings are escaped per RFC 8259")
  func escapesStrings() {
    #expect(OrderedJSON.quote("a\"b") == "\"a\\\"b\"")
    #expect(OrderedJSON.quote("a\\b") == "\"a\\\\b\"")
    #expect(OrderedJSON.quote("a\nb") == "\"a\\nb\"")
    #expect(OrderedJSON.quote("a\u{01}b") == "\"a\\u0001b\"")
    // Non-ASCII stays raw: valid JSON, and readable in review.
    #expect(OrderedJSON.quote("café") == "\"café\"")
  }

  @Test("Empty containers stay on one line")
  func emptyContainers() {
    #expect(OrderedJSON.array([]).serialized() == "[]\n")
    #expect(OrderedJSON.object([]).serialized() == "{}\n")
  }
}
