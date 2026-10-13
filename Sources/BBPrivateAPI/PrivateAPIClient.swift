//  PrivateAPIClient
//  The typed contract, expressed over whichever transport is connected.
//
//  This is the only place in the server that knows which helper action a contract method
//  maps to and which fields it carries. Everything above it calls typed methods; everything
//  below it moves bytes. That split is what lets the legacy Objective-C helper and the Swift
//  one coexist behind one API.
//
//  Actions are `MessagesHelperAction` / `FaceTimeHelperAction` and fields are `WireKey`, both
//  from the contract the helpers link, so a spelling exists once. Their raw values are the
//  SHIPPING helper's, verbatim: `backwardsCompatibilityMessage`, `selectedMessageGuid`,
//  `ddScan` as 0/1 rather than a boolean. They look inconsistent because they are; they are
//  also the wire, so they are reproduced rather than tidied. The Swift helper accepts
//  exactly these.
//
//  The conformance is split by role, one extension per role in
//  `PrivateAPIClient+<Group>.swift`: `+Sending`, `+Messages`, `+Chats`, `+Account`,
//  `+FindMy` and `+FaceTime`. This file holds the type, the `PrivateAPIConnection` role
//  and the two shapes more than one role file uses (`chatAction` and `sentMessage`), so
//  each is written once. A shape only one role uses stays private beside that role.
//
//  See `.claude/docs/private-api.md`.

import BBPrivateAPIContract
import Foundation

public actor PrivateAPIClient: PrivateAPI {

  let transport: any PrivateAPITransport

  public init(transport: any PrivateAPITransport) {
    self.transport = transport
  }

  public var isConnected: Bool {
    get async { await transport.isConnected }
  }

  public nonisolated var events: AsyncStream<PrivateAPIEvent> {
    // The transport owns the stream; this is a pass-through so callers do not need to
    // know which transport is in play.
    let transport = transport
    return AsyncStream { continuation in
      let task = Task {
        for await event in await transport.events {
          continuation.yield(event)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Shared shapes

  func chatAction(_ action: MessagesHelperAction, _ chat: ChatIdentifier) async throws {
    try await transport.request(
      action: action, data: .object([.chatGuid: .string(chat.rawValue)])
    )
  }

  /// The helper confirms a send with `identifier`, the new message's GUID.
  ///
  /// The authoritative record still arrives through the chat.db change detector; this is
  /// what lets the two be correlated rather than producing a duplicate.
  func sentMessage(from result: WireJSON?, chat: ChatIdentifier) throws -> SentMessage {
    guard
      let identifier = result?[.identifier]?.stringValue
        ?? result?[.guid]?.stringValue
        ?? result?.stringValue
    else {
      throw PrivateAPIError.rejectedByMessages(reason: "the helper returned no message identifier")
    }
    return SentMessage(guid: MessageGUID(identifier), chat: chat, sentAt: Date())
  }
}
