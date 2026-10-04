//  UnknownChatQueryTests
//  `POST /message/query` with a chatGuid that names no chat.
//
//  The reference short-circuits before it queries anything (`messageRouter.ts:144`) and all
//  three parts of its answer are contractual: a 200, `data: []`, and
//  `No chat found with GUID: <guid>`. We ran the query instead — which returns the same
//  empty array, under the generic success sentence, with a full metadata block. A client
//  cannot then tell "this chat has no messages matching your filter" from "there is no such
//  chat", which is the only question this case answers.
//
//  The `message` field is one of the three literals the parity diff treats as contractual,
//  so this is a wire difference and not a nicety.
//
//  **The trap is the lookup, not the short-circuit.** A chat GUID's service prefix is not
//  part of its identity, and on macOS 26 every stored prefix is the literal `any` — so a
//  short-circuit that compared the client's string to the stored one would report EVERY chat
//  missing on a Tahoe host, turning a wire-shape fix into a total outage of the route. The
//  last test here is that one, and it is the reason this goes through
//  `ChatInterface.find`. See CLAUDE.md rule 3.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBContacts
import BBHTTPAPI
import BBIMessage
import BBMedia
import BBPersistence
import BBSerialization
import Foundation
import GRDB
import Testing

@testable import BBHandlers
@testable import BBInterfaces

@Suite("Unknown chat on message query")
struct UnknownChatQueryTests {

  /// Everything `registerMessage` asks for, and nothing more.
  private struct Host: InterfaceProviding, AttachmentConverting {
    let built: ServerInterfaces
    let attachmentConversion = AttachmentConversion()
    func interfaces() async -> ServerInterfaces? { built }
    func requireInterfaces() async throws -> ServerInterfaces { built }
  }

  /// The real fixture database, read-only, at a throwaway path.
  private func registry() async throws -> HandlerRegistry {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("BBIMessageTests/ChatDBFixtures/chat-sonoma.db")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-unknownchat-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)
    let serializer = MessageSerializer(profile: profile)

    let appQueue = try DatabaseQueue()
    let appDatabase = AppDatabase(queue: appQueue)
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
          contact: ContactInterface(index: ContactIndex(database: appDatabase)),
          conversations: ConversationDirectory(
            repository: repository, contacts: ContactIndex(database: appDatabase)),
          transcript: TranscriptInterface(
            repository: repository, serializer: serializer,
            attachments: AttachmentInterface(repository: repository),
            conversations: ConversationDirectory(
              repository: repository, contacts: ContactIndex(database: appDatabase)))
        )
      )
    )
    return registry
  }

  private func query(chatGuid: String?) async throws -> RouteResult {
    let registry = try await registry()
    let handler = try #require(registry.handler(for: .messageQuery))
    var body: [String: JSONValue] = ["limit": .int(10)]
    if let chatGuid { body["chatGuid"] = .string(chatGuid) }
    return try await handler(
      APIRequestContext(
        method: .post, path: "/api/v1/message/query",
        headers: ["content-type": "application/json"],
        body: try JSONValue.object(body).serialize()))
  }

  private func parts(
    _ response: RouteResult
  ) -> (data: JSONValue?, metadata: JSONValue?, message: String?) {
    guard case .data(let data, let metadata, let message) = response else {
      Issue.record("expected a data response, got \(response)")
      return (nil, nil, nil)
    }
    return (data, metadata, message)
  }

  @Test("An unknown chat GUID answers with the reference's sentence and an empty array")
  func unknownChatShortCircuits() async throws {
    let guid = "any;-;chat000000000000000099"
    let parts = parts(try await query(chatGuid: guid))

    #expect(parts.message == "No chat found with GUID: \(guid)")
    #expect(parts.data == .array([]))
  }

  @Test("It carries no metadata, which is how a client tells the two cases apart")
  func unknownChatOmitsMetadata() async throws {
    // The part most likely to be "tidied" back in by someone adding a metadata block to
    // every listing. The reference's `Success` here is constructed with `message` and
    // `data` alone, and an offset/limit/total block describing a query that never ran is
    // worse than absent.
    #expect(parts(try await query(chatGuid: "any;-;chat000000000000000099")).metadata == nil)
  }

  @Test("A known chat still runs the query and still reports metadata")
  func knownChatIsUnaffected() async throws {
    // The control: a short-circuit that fired for everything would pass both tests above.
    let parts = parts(try await query(chatGuid: "iMessage;-;+12025550143"))

    #expect(parts.message != "No chat found with GUID: iMessage;-;+12025550143")
    #expect(parts.metadata != nil, "a real listing keeps its offset/limit/total")
  }

  @Test("No chatGuid at all is not a short-circuit")
  func absentChatGuidQueriesEverything() async throws {
    #expect(parts(try await query(chatGuid: nil)).metadata != nil)
  }

  @Test("A different service prefix names the SAME chat and must not short-circuit")
  func servicePrefixIsNotIdentity() async throws {
    // The rule-3 trap, and the reason this uses `ChatInterface.find`. The fixture stores
    // `iMessage;-;…`; a client on a Tahoe host sends `any;-;…` for the same conversation.
    // A short-circuit comparing strings would answer "no chat found" for every chat on the
    // machine — a far worse regression than the wire difference being fixed.
    let parts = parts(try await query(chatGuid: "any;-;+12025550143"))

    #expect(
      parts.message != "No chat found with GUID: any;-;+12025550143",
      "a prefix difference is not a different chat")
    #expect(parts.metadata != nil)
  }
}
