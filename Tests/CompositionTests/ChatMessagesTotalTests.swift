//  ChatMessagesTotalTests
//  `GET /chat/:guid/message` reports a total for the rows it was asked for.
//
//  The route filters its rows by `after` and `before` and counted the whole conversation for
//  `metadata.total`. A client syncing "everything since" its last visit was told the size of
//  the chat, and paged against a number that described none of the pages. The reference
//  counts with the same query it pages with (`getManyAndCount` in
//  `databases/imessage/index.ts` `getMessages`), and `/message/query` already did; this is
//  the second route that pages messages, held to the same rule.
//
//  Asserted against the committed Sonoma fixture: its direct chat holds four messages, a
//  minute apart from 2024-06-01T12:00:00Z (ROWIDs 1, 2, 3 and 5).
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

@Suite("Chat message listing total", .removingChatDBCopies)
struct ChatMessagesTotalTests {

  /// Everything `registerChat` asks for, and nothing more.
  private struct Host: InterfaceProviding, AttachmentConverting {
    let built: ServerInterfaces
    let attachmentConversion = AttachmentConversion()
    func interfaces() async -> ServerInterfaces? { built }
    func requireInterfaces() async throws -> ServerInterfaces { built }
  }

  /// The fixture's direct chat.
  private static let chatGUID = "iMessage;-;+12025550143"

  /// The second message's timestamp, in the epoch milliseconds a client sends.
  private static let secondMessage = "1717243260000"

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
          message: MessageInterface(repository: repository, serializer: serializer),
          chat: ChatInterface(repository: repository, serializer: serializer),
          handle: HandleInterface(repository: repository),
          attachment: AttachmentInterface(repository: repository),
          contact: ContactInterface(index: ContactIndex(database: appDatabase))
        )
      )
    )
    return registry
  }

  /// The page's row count and its `metadata.total`.
  private func listing(_ parameters: [String: String]) async throws -> (rows: Int, total: Int?) {
    let registry = try await registry()
    let handler = try #require(registry.handler(for: .chatMessages))
    let response = try await handler(
      APIRequestContext(
        method: .get, path: "/api/v1/chat/\(Self.chatGUID)/message",
        queryParameters: parameters, pathParameters: ["guid": Self.chatGUID]))
    guard case .data(let data, let metadata, _) = response, case .array(let rows)? = data else {
      Issue.record("expected a page of messages, got \(response)")
      return (0, nil)
    }
    return (rows.count, metadata?["total"]?.intValue)
  }

  @Test("Unfiltered, the total is the whole conversation")
  func unfilteredTotal() async throws {
    // The control: the fix must not change what an unfiltered page reports.
    let page = try await listing([:])
    #expect(page.rows == 4)
    #expect(page.total == 4)
  }

  @Test("`after` narrows the total exactly as it narrows the rows")
  func afterNarrowsTheTotal() async throws {
    // Inclusive, as the rows are: the second, third and fourth messages.
    let page = try await listing(["after": Self.secondMessage])
    #expect(page.rows == 3)
    #expect(page.total == page.rows, "a total of \(page.total ?? -1) for \(page.rows) rows")
  }

  @Test("`before` narrows the total exactly as it narrows the rows")
  func beforeNarrowsTheTotal() async throws {
    let page = try await listing(["before": Self.secondMessage])
    #expect(page.rows == 2)
    #expect(page.total == page.rows, "a total of \(page.total ?? -1) for \(page.rows) rows")
  }

  @Test("The total counts every page, not the one returned")
  func totalIsNotThePageSize() async throws {
    // A window narrower than the filtered set: the total is still the filtered set.
    let page = try await listing(["after": Self.secondMessage, "limit": "1"])
    #expect(page.rows == 1)
    #expect(page.total == 3)
  }
}
