//  GenmojiLibraryHandlerTests
//  The Genmoji library routes as a client meets them: the 304, the refusals, and the shapes
//  the document declares.
//
//  The listing and image handlers are driven over a library with no store behind it, which is
//  enough for what only the handler decides: reading `If-None-Match`, the query refusals, and
//  the empty-with-a-reason answer. What the store holds is `StickerGenmojiTests` and
//  `GenmojiLibraryInterfaceTests`.

import BBCore
import BBHTTPAPI
import BBIMessage
import BBInterfaces
import BBOpenAPI
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("Genmoji library routes")
struct GenmojiLibraryHandlerTests {

  static let empty = GenmojiLibraryInterface(repository: nil)

  @Test("The listing is cached, and the same request with its tag is a 304")
  func listingRevalidates() async throws {
    let first = try await GenmojiHandlers.genmojiLibrary(
      APIRequestContext(method: .get, path: "/api/v2/genmoji/library"), library: Self.empty)
    guard case .cached(.data(let data, let metadata, _), let validation) = first else {
      Issue.record("expected a cached listing, got \(first)")
      return
    }
    #expect(data == .array([]))
    guard case .object(let fields)? = metadata else {
      Issue.record("expected metadata")
      return
    }
    // No store: empty, with the reason, as the sticker library answers.
    #expect(fields["reason"] == .string(GenmojiLibraryInterface.absentSentence))
    #expect(fields["revision"]?.stringValue?.count == 16)
    #expect(fields["total"] == .int(0))

    let again = try await GenmojiHandlers.genmojiLibrary(
      APIRequestContext(
        method: .get, path: "/api/v2/genmoji/library",
        headers: ["if-none-match": validation.entityTag]),
      library: Self.empty)
    guard case .notModified(let repeated) = again else {
      Issue.record("expected a 304, got \(again)")
      return
    }
    #expect(repeated == validation)

    // Another page is another answer, whatever tag it is sent with.
    let otherPage = try await GenmojiHandlers.genmojiLibrary(
      APIRequestContext(
        method: .get, path: "/api/v2/genmoji/library", queryParameters: ["offset": "100"],
        headers: ["If-None-Match": validation.entityTag]),
      library: Self.empty)
    guard case .cached = otherPage else {
      Issue.record("a different page answered 304 for the first page's tag")
      return
    }
  }

  @Test("The image route refuses a size or format it cannot serve, before looking anything up")
  func imageRefusals() async throws {
    for query in [["size": "0"], ["size": "wide"], ["format": "jpeg"]] {
      await #expect(throws: BadRequest.self, "\(query)") {
        try await GenmojiHandlers.genmojiLibraryImage(
          Self.imageRequest(query), library: Self.empty)
      }
    }
    // In range for the query accessor, out of range for the route.
    await #expect(throws: InterfaceError.self) {
      try await GenmojiHandlers.genmojiLibraryImage(
        Self.imageRequest(["size": "2048"]), library: Self.empty)
    }
  }

  @Test("An image of a Genmoji this Mac does not have is not found")
  func imageNotFound() async throws {
    await #expect(throws: InterfaceError.self) {
      try await GenmojiHandlers.genmojiLibraryImage(Self.imageRequest([:]), library: Self.empty)
    }
  }

  @Test("The batch route requires identifiers and a format it knows")
  func batchRefusals() async throws {
    for body in [#"{}"#, #"{"identifiers": "x"}"#, #"{"identifiers": ["x"], "format": "gif"}"#] {
      await #expect(throws: BadRequest.self, "\(body)") {
        try await GenmojiHandlers.genmojiLibraryImages(
          APIRequestContext(
            method: .post, path: "/api/v2/genmoji/library/images", body: Data(body.utf8)),
          library: Self.empty)
      }
    }
  }

  @Test("Identifiers that name nothing come back in `missing`, not as a refusal")
  func batchMissing() async throws {
    let result = try await GenmojiHandlers.genmojiLibraryImages(
      APIRequestContext(
        method: .post, path: "/api/v2/genmoji/library/images",
        body: Data(#"{"identifiers": ["11111111-2222-4333-8444-555555555555"]}"#.utf8)),
      library: Self.empty)
    guard case .data(let data, _, _) = result, case .object(let fields)? = data else {
      Issue.record("expected an object")
      return
    }
    #expect(fields["images"] == .array([]))
    #expect(fields["missing"] == .array([.string("11111111-2222-4333-8444-555555555555")]))
  }

  // MARK: - Shapes against the document

  @Test("A listed Genmoji carries exactly the declared fields")
  func listedShape() throws {
    let row = GenmojiRow(
      identifier: "11111111-2222-4333-8444-555555555555", description: "a teal circle",
      languageIdentifier: nil, createdAt: nil, lastUsedAt: nil, shelves: [.recent, .saved],
      stickerIdentifiers: ["11111111-2222-4333-8444-555555555555"],
      renditions: [
        GenmojiRendition(
          identifier: "R", role: "r", uti: "public.heic", width: 96, height: 96, byteCount: 1,
          key: 1)
      ])
    let serialized = GenmojiLibraryInterface.serialize(row)
    guard case .object(let fields) = serialized else {
      Issue.record("expected an object")
      return
    }
    let declared = try #require(ResponseBodies.byHandler[.genmojiLibrary]?.variants.first)
    #expect(Set(fields.keys) == Set(declared.properties.map(\.name)))
    #expect(fields["shelves"] == .array([.string("saved"), .string("recent")]))
    #expect(fields["sizes"] == .array([.int(96)]))
  }

  @Test("A batch carries exactly the declared fields, images included")
  func batchShape() throws {
    let batch = GenmojiLibraryInterface.Batch(
      images: [
        GenmojiLibraryInterface.Image(
          identifier: "11111111-2222-4333-8444-555555555555", data: Data([1]),
          contentType: "image/png", width: 1, height: 1)
      ],
      missing: [])
    guard case .object(let fields) = GenmojiLibraryInterface.serialize(batch),
      case .array(let images)? = fields["images"], case .object(let image)? = images.first
    else {
      Issue.record("expected an object with one image")
      return
    }
    let declared = try #require(ResponseBodies.byHandler[.genmojiLibraryImages]?.variants.first)
    #expect(Set(fields.keys) == Set(declared.properties.map(\.name)))
    let imageProperty = try #require(declared.properties.first { $0.name == "images" })
    guard case .array(of: .object(let nested)) = imageProperty.schema else {
      Issue.record("`images` is not declared as an array of objects")
      return
    }
    #expect(Set(image.keys) == Set(nested.map(\.name)))
  }

  @Test("A deletion carries exactly the declared fields")
  func deletedShape() throws {
    let serialized = GenmojiLibraryInterface.serialize(
      GenmojiLibraryInterface.Deleted(
        identifier: "11111111-2222-4333-8444-555555555555",
        stickerIdentifiers: ["11111111-2222-4333-8444-555555555555"]))
    guard case .object(let fields) = serialized else {
      Issue.record("expected an object")
      return
    }
    let declared = try #require(ResponseBodies.byHandler[.genmojiLibraryDelete]?.variants.first)
    #expect(Set(fields.keys) == Set(declared.properties.map(\.name)))
  }

  static func imageRequest(_ query: [String: String]) -> APIRequestContext {
    APIRequestContext(
      method: .get, path: "/api/v2/genmoji/library/x/image", queryParameters: query,
      pathParameters: ["id": "11111111-2222-4333-8444-555555555555"])
  }
}
