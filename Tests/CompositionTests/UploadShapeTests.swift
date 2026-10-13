//  UploadShapeTests
//  `POST /attachment/upload`, diffed against the recorded reference.
//
//  Deny-listed from replay by its Private API gate, so `FixtureReplayTests` never sends it,
//  and `DenyListedShapeCoverageTests` is the ratchet that names this suite as the one that
//  compares it instead. The REAL handler runs here, against the recorded form, with no helper
//  behind it: the upload itself never touches Messages, only the gate in front of it does.
//
//  The drift this caught: the route answered `{ path, name, size }`, with `path` this Mac's
//  absolute path, against the reference's `{ path: "<uuid>/<file>" }`
//  (`attachmentRouter.ts:187-194`). Nothing read `name` or `size`, so they were removed rather
//  than declared, and `path` now has the reference's form.

import BBCore
import BBHTTPAPI
import BBInterfaces
import BBMedia
import BBSerialization
import BBTestSupport
import Foundation
import Testing

@testable import BBHandlers

@Suite("Attachment upload response shape")
struct UploadShapeTests {

  static let fixture = "post_api_v1_attachment_upload-5baa61-200.json"

  /// Uploads only. No interfaces: the handler must not need them, and a test that supplied
  /// them would hide one that started to.
  private struct UploadHost: InterfaceProviding, UploadStoring, SendDeduplicating {
    let uploads: UploadStore
    let sendCache = SendCache()
    func interfaces() async -> ServerInterfaces? { nil }
    func requireInterfaces() async throws -> ServerInterfaces {
      throw InterfaceError.unavailable("not needed to stage an upload")
    }
  }

  /// Runs the registered handler on the recorded request and returns `data`, with the store.
  private func upload() async throws -> (data: [String: JSONValue], uploads: UploadStore) {
    let uploads = UploadStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("bb-upload-shape-\(UUID().uuidString)"))
    var registry = HandlerRegistry()
    UploadHandlers.register(into: &registry, context: UploadHost(uploads: uploads))
    let handler = try #require(registry.handler(for: .attachmentUpload))

    let request = try #require(try Self.recorded()["request"])
    let contentType = try #require(request["headers"]?["content-type"]?.stringValue)
    let body = try #require(request["body"]?["value"]?.stringValue)

    let result = try await handler(
      APIRequestContext(
        method: .post, path: "/api/v1/attachment/upload",
        headers: ["Content-Type": contentType], body: Data(body.utf8)))
    guard case .data(let data?, _, _) = result, case .object(let object) = data else {
      Issue.record("expected an object in `data`, got \(result)")
      return ([:], uploads)
    }
    return (object, uploads)
  }

  private static func recorded() throws -> JSONValue {
    try JSONValue.parse(try Data(contentsOf: Repository.url("Fixtures/http/\(fixture)")))
  }

  /// The reference's `data`, as the Node server sent it.
  private func recordedData() throws -> [String: JSONValue] {
    let data = try #require(try Self.recorded()["response"]?["body"]?["value"]?["data"])
    guard case .object(let object) = data else {
      Issue.record("the recorded `data` is not an object")
      return [:]
    }
    return object
  }

  @Test("The upload answers exactly the keys the reference sends")
  func keysMatchTheRecordedResponse() async throws {
    let theirs = Set(try recordedData().keys)
    let ours = Set(try await upload().data.keys)

    // Stated so the comparison cannot pass by diffing two empty sets.
    #expect(theirs == ["path"])
    #expect(
      theirs.subtracting(ours).sorted() == [],
      "fields the reference sends on POST /attachment/upload and we do not")
    // No declared additions: a key here is drift until someone writes down why it is kept.
    #expect(
      ours.subtracting(theirs).sorted() == [],
      "fields we add to POST /attachment/upload")
  }

  @Test("`path` is `<uuid>/<file>`, as the reference's is")
  func pathHasTheReferenceForm() async throws {
    let theirs = try #require(try recordedData()["path"]?.stringValue)
    let ours = try #require(try await upload().data["path"]?.stringValue)

    // The recorded UUID was mangled by the corpus redactor (a digit run became a phone
    // number), so the reference's half is checked for its structure and its filename only.
    let theirParts = theirs.split(separator: "/", omittingEmptySubsequences: false)
    let ourParts = ours.split(separator: "/", omittingEmptySubsequences: false)
    #expect(theirParts.count == 2)
    #expect(ourParts.count == 2, "\(ours) is not <uuid>/<file>")
    #expect(ourParts.last == theirParts.last, "the file keeps the part's filename")

    let uuid = String(ourParts[0])
    #expect(UUID(uuidString: uuid) != nil, "\(uuid) is not a UUID")
    #expect(uuid == uuid.lowercased(), "uuidv4() is lowercase")
  }

  @Test("The path it answers with is the one a send accepts back")
  func pathRoundTrips() async throws {
    let (data, uploads) = try await upload()
    let path = try #require(data["path"]?.stringValue)

    // What `message/attachment`, `message/multipart` and `chat/:guid/icon` each do with it.
    let resolved = try uploads.confined(path)
    #expect(FileManager.default.fileExists(atPath: resolved))
    #expect((resolved as NSString).lastPathComponent == "fixture.png")
  }
}
