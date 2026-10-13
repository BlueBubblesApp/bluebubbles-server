//  AttachmentChunkTests
//  `POST /message/attachment/chunk` takes the reference's request, through the real handler.
//
//  The route's handler read JSON (`attachmentChunkData` in base64, `attachmentName`, `index`)
//  while its validation applied the reference's rule set (`name`, `chunkIndex`,
//  `totalChunks`), so no request could satisfy both, and the reference's own request — the
//  multipart form the recorded fixture holds — failed in the handler. `SendShapeTests`
//  compared the RESPONSE and so could not see it. These drive the REQUEST.
//
//  No send reaches Messages: the helper here refuses every call, and the AppleScript runner
//  fails, so the completing request is followed exactly as far as Messages and stopped there.

import BBAppleScript
import BBContacts
import BBCore
import BBHTTPAPI
import BBMedia
import BBPersistence
import BBSerialization
import BBTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import BBHandlers
@testable import BBInterfaces

@Suite("Attachment chunk route")
struct AttachmentChunkTests {

  static let fixture = "post_api_v1_message_attachment_chunk-5baa61-200.json"
  static let transfer = "fixture-chunk-transfer"

  // MARK: - Harness

  private struct Host: InterfaceProviding, UploadStoring, SendDeduplicating {
    let uploads: UploadStore
    let built: ServerInterfaces?
    let sendCache = SendCache()
    func interfaces() async -> ServerInterfaces? { built }
    func requireInterfaces() async throws -> ServerInterfaces {
      guard let built else { throw InterfaceError.unavailable("no interfaces in this test") }
      return built
    }
  }

  private struct FailingRunner: AppleScriptRunning {
    func run(
      key: String, source: String, handler: String,
      arguments: [AppleScriptValue], target: String, timeout: Duration
    ) async throws -> String? {
      throw MessageSendError.scriptFailed(number: -1, message: "refused in a test")
    }
  }

  /// Interfaces whose every route to Messages refuses. `FailingPrivateAPI` reports itself
  /// connected, so the send takes the helper and is refused there; the failing runner is the
  /// second guard, should anything ever fall back to AppleScript.
  private static func refusingInterfaces() throws -> ServerInterfaces {
    let repository = try InterfaceFixtures.repository()
    let serializer = InterfaceFixtures.serializer
    return ServerInterfaces(
      message: MessageInterface(
        repository: repository, serializer: serializer, privateAPI: FailingPrivateAPI(),
        appleScript: AppleScriptMessageSender(runner: FailingRunner())),
      chat: ChatInterface(repository: repository, serializer: serializer),
      handle: HandleInterface(repository: repository),
      attachment: AttachmentInterface(repository: repository),
      contact: ContactInterface(index: ContactIndex(database: try contacts()))
    )
  }

  private static func contacts() throws -> AppDatabase {
    let database = AppDatabase(queue: try DatabaseQueue())
    try database.migrate(contributors: [ContactsSchema.self])
    return database
  }

  private func host(sending: Bool = false) throws -> Host {
    Host(
      uploads: UploadStore(
        directory: FileManager.default.temporaryDirectory
          .appendingPathComponent("bb-chunks-\(UUID().uuidString)")),
      built: sending ? try Self.refusingInterfaces() : nil)
  }

  private func run(_ request: APIRequestContext, on host: Host) async throws -> RouteResult {
    var registry = HandlerRegistry()
    UploadHandlers.register(into: &registry, context: host)
    let handler = try #require(registry.handler(for: .messageSendAttachmentChunk))
    return try await handler(request)
  }

  /// A chunk request in the reference's shape: text fields, then the slice under `chunk`.
  private func form(
    index: Int, total: Int, complete: Bool, chunk: Data? = Data("slice".utf8),
    name: String = "clip.mov"
  ) -> APIRequestContext {
    let boundary = "bb-chunk-boundary"
    var body = Data()
    for (field, value) in [
      ("attachmentGuid", Self.transfer), ("chatGuid", "any;-;person@example.com"),
      ("name", name), ("chunkIndex", "\(index)"), ("totalChunks", "\(total)"),
      ("isComplete", complete ? "true" : "false"),
    ] {
      body.append(
        Data(
          "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n"
            .utf8))
    }
    if let chunk {
      body.append(
        Data(
          ("--\(boundary)\r\nContent-Disposition: form-data; name=\"chunk\"; "
            + "filename=\"blob\"\r\nContent-Type: application/octet-stream\r\n\r\n").utf8))
      body.append(chunk)
      body.append(Data("\r\n".utf8))
    }
    body.append(Data("--\(boundary)--\r\n".utf8))
    return APIRequestContext(
      method: .post, path: "/api/v1/message/attachment/chunk",
      headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"], body: body)
  }

  /// The recorded request, exactly as the reference received it.
  private func recordedRequest() throws -> APIRequestContext {
    let recorded = try JSONValue.parse(
      try Data(contentsOf: Repository.url("Fixtures/http/\(Self.fixture)")))
    let request = try #require(recorded["request"])
    return APIRequestContext(
      method: .post, path: "/api/v1/message/attachment/chunk",
      headers: ["Content-Type": try #require(request["headers"]?["content-type"]?.stringValue)],
      body: Data(try #require(request["body"]?["value"]?.stringValue).utf8))
  }

  /// The files the store assembled: one `<uuid>/<name>` per completing request that got
  /// as far as assembly.
  private func assembled(in uploads: UploadStore) throws -> [URL] {
    let manager = FileManager.default
    return try manager.contentsOfDirectory(at: uploads.directory, includingPropertiesForKeys: nil)
      .filter { !$0.lastPathComponent.hasPrefix("chunks-") }
      .flatMap { try manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
  }

  private func rendered(_ error: any Error) throws -> (status: Int, envelope: JSONValue) {
    let (status, envelope) = ErrorRenderer.render(error, logger: Logger(label: "test"))
    return (status, try JSONValue.parse(try envelope.encoded()))
  }

  // MARK: - The recorded request

  @Test("The recorded request reads as the reference's fields and slice")
  func recordedRequestParses() throws {
    let (values, chunk) = try UploadHandlers.chunkRequest(try recordedRequest())
    #expect(values.string("name") == "fixture.png")
    #expect(values.string("attachmentGuid")?.hasPrefix("fixture-chunk-") == true)
    #expect(try UploadHandlers.chunkNumber("chunkIndex", in: values) == 0)
    #expect(try UploadHandlers.chunkNumber("totalChunks", in: values) == 1)
    #expect(values.truthy("isComplete"))
    #expect((chunk?.count ?? 0) > 0, "the slice is the `chunk` part")
  }

  @Test("The recorded request is stored, assembled under `name`, and sent")
  func recordedRequestReachesTheSend() async throws {
    let host = try host(sending: true)
    // Refused by the helper, which is the point: it got there.
    let error = await #expect(throws: (any Error).self) {
      _ = try await run(try recordedRequest(), on: host)
    }
    let (status, envelope) = try rendered(try #require(error))
    #expect(status == 500)
    #expect(envelope["error"]?["type"]?.stringValue == "iMessage Error")
    #expect(envelope["error"]?["message"]?.stringValue?.contains("Missing chunks") == false)

    let files = try assembled(in: host.uploads)
    #expect(files.map(\.lastPathComponent) == ["fixture.png"])
  }

  // MARK: - Slices before the last

  @Test("A slice that does not complete answers with the reference's keys and message")
  func intermediateSlice() async throws {
    // No interfaces: storing a slice must not need chat.db or Messages.
    let result = try await run(form(index: 1, total: 3, complete: false), on: try host())
    guard case .data(let data?, _, let message) = result else {
      Issue.record("expected data, got \(result)")
      return
    }
    #expect(
      data
        == .object([
          "attachmentGuid": .string(Self.transfer), "chunkIndex": .int(1),
          "totalChunks": .int(3), "remainingChunks": .int(1),
        ]))
    #expect(message == "Chunk 1/2 uploaded successfully.")
  }

  @Test("Slices may arrive in any order and are joined by index")
  func outOfOrderSlices() async throws {
    let host = try host(sending: true)
    for index in [2, 0] {
      _ = try await run(
        form(index: index, total: 3, complete: false, chunk: Data("\(index)".utf8)), on: host)
    }
    // The last INDEX arrived first; only `isComplete` sends, on whichever slice carries it.
    _ = try? await run(form(index: 1, total: 3, complete: true, chunk: Data("1".utf8)), on: host)

    let files = try assembled(in: host.uploads)
    #expect(files.map(\.lastPathComponent) == ["clip.mov"])
    #expect(try Data(contentsOf: try #require(files.first)) == Data("012".utf8))
  }

  @Test("A completing request whose send fails can be retried and finds every slice")
  func failedSendKeepsTheSlices() async throws {
    let host = try host(sending: true)
    _ = try await run(form(index: 0, total: 2, complete: false), on: host)
    for _ in 0..<2 {
      let error = await #expect(throws: (any Error).self) {
        _ = try await run(form(index: 1, total: 2, complete: true), on: host)
      }
      // The send's refusal both times; never "Missing chunks", which is what deleting the
      // slices before the send had worked would have produced on the retry.
      let (_, envelope) = try rendered(try #require(error))
      #expect(envelope["error"]?["message"]?.stringValue?.contains("Missing chunks") == false)
    }
    #expect(try assembled(in: host.uploads).count == 2)
  }

  @Test("A slice is stored under the sanitised `name` the transfer gives")
  func nameIsSanitised() async throws {
    let host = try host(sending: true)
    _ = try? await run(
      form(index: 0, total: 1, complete: true, name: #"C:\Users\someone\clip.mov"#), on: host)
    #expect(try assembled(in: host.uploads).map(\.lastPathComponent) == ["clip.mov"])
  }

  // MARK: - Refusals, in the reference's words

  @Test("Completing a transfer with a slice missing is the reference's 500")
  func missingSlice() async throws {
    let host = try host(sending: true)
    let error = await #expect(throws: (any Error).self) {
      _ = try await run(form(index: 1, total: 2, complete: true), on: host)
    }
    let (status, envelope) = try rendered(try #require(error))
    #expect(status == 500)
    #expect(envelope["message"]?.stringValue == "Attachment Chunk Send Error")
    #expect(envelope["error"]?["type"]?.stringValue == "iMessage Error")
    #expect(
      envelope["error"]?["message"]?.stringValue
        == "Missing chunks. Expected 2 chunks, but found 1.")
  }

  @Test("No slice, an empty slice and a JSON body are each the validator's one refusal")
  func noSlice() async throws {
    let json = APIRequestContext(
      method: .post, path: "/api/v1/message/attachment/chunk",
      headers: ["Content-Type": "application/json"],
      body: Data(#"{"attachmentGuid":"t","name":"x.png","chunkIndex":0,"totalChunks":1}"#.utf8))
    for request in [
      form(index: 0, total: 1, complete: false, chunk: nil),
      form(index: 0, total: 1, complete: false, chunk: Data()),
      json,
    ] {
      let error = await #expect(throws: BadRequest.self) {
        _ = try await run(request, on: try host())
      }
      #expect(error?.errorMessage == ReferenceMessages.chunkNotProvided)
    }
  }

  @Test("An index at or past the total is refused before anything is stored")
  func indexPastTheEnd() async throws {
    let host = try host()
    let error = await #expect(throws: BadRequest.self) {
      _ = try await run(form(index: 2, total: 2, complete: false), on: host)
    }
    #expect(error?.errorMessage == ReferenceMessages.chunkIndexOutOfRange)
    #expect(!FileManager.default.fileExists(atPath: host.uploads.directory.path))
  }
}
