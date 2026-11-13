//  HandleQueryPagingTests
//  `POST /handle/query` pages by the reference's default and reads its paging fields as the
//  reference does.
//
//  The reference reads both with `Number.parseInt`, defaulting `limit` to 100. This route
//  defaulted to 1000, and read a `limit` of `"1"` or `1.0` as absent, which the validator's
//  `numeric` rule had already passed; both answered a 200 with a page the client did not ask
//  for.
//
//  Asserted against the committed Sonoma fixture, which holds three handles.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBContacts
import BBCore
import BBHTTPAPI
import BBIMessage
import BBMedia
import BBPersistence
import BBSerialization
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBHandlers
@testable import BBInterfaces

@Suite("Handle query paging", .removingChatDBCopies)
struct HandleQueryPagingTests {

  /// Everything `registerHandle` asks for, and nothing more.
  private struct Host: InterfaceProviding, AttachmentConverting {
    let built: ServerInterfaces
    let attachmentConversion = AttachmentConversion()
    func interfaces() async -> ServerInterfaces? { built }
    func requireInterfaces() async throws -> ServerInterfaces { built }
  }

  private func registry() async throws -> HandlerRegistry {
    let path = try CommittedChatDB.copy()
    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)
    let serializer = MessageSerializer(profile: profile)

    let appDatabase = AppDatabase(queue: try DatabaseQueue())
    try appDatabase.migrate(contributors: [ContactsSchema.self])

    var registry = HandlerRegistry()
    ReadHandlers.register(
      into: &registry,
      context: Host(
        built: ServerInterfaces(
          message: MessageInterface(
            repository: repository, serializer: serializer, appleScript: InterfaceFixtures.noSender),
          chat: ChatInterface(
            repository: repository, serializer: serializer, appleScript: InterfaceFixtures.noSender),
          handle: HandleInterface(repository: repository),
          attachment: AttachmentInterface(repository: repository),
          contact: ContactInterface(index: ContactIndex(database: appDatabase))
        )
      )
    )
    return registry
  }

  /// The page's row count and its metadata, for a body sent as these exact bytes, so that a
  /// `1.0` reaches the handler as the double a client's JSON makes it.
  private func page(_ body: String) async throws -> (rows: Int, metadata: JSONValue?) {
    let registry = try await registry()
    let handler = try #require(registry.handler(for: .handleQuery))
    let response = try await handler(
      APIRequestContext(
        method: .post, path: "/api/v1/handle/query",
        headers: ["content-type": "application/json"],
        body: Data(body.utf8)))
    guard case .data(let data, let metadata, _) = response, case .array(let rows)? = data else {
      Issue.record("expected a page of handles, got \(response)")
      return (0, nil)
    }
    return (rows.count, metadata)
  }

  @Test("An absent limit is the reference's 100")
  func defaultLimit() async throws {
    let page = try await page("{}")
    #expect(page.metadata?["limit"] == .int(100))
    #expect(page.metadata?["offset"] == .int(0))
    #expect(page.rows == 3)
  }

  @Test(
    "A quoted or whole-double limit and offset are applied",
    arguments: [#"{"limit":"1","offset":"1"}"#, #"{"limit":1.0,"offset":1.0}"#])
  func spelledPaging(body: String) async throws {
    let page = try await page(body)
    #expect(page.rows == 1)
    #expect(page.metadata?["limit"] == .int(1))
    #expect(page.metadata?["offset"] == .int(1))
  }
}
