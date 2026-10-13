//  ChatMessageReaderTests
//  The chat interface reads messages through one held message interface, not one per call.
//
//  A `MessageInterface` carries the attachment-metadata cache, and `ChatInterface` built a
//  fresh one for every chat-scoped read and every create, so each started with that cache
//  empty. The interface is held now, and the composition root hands it the bundle's own.

import BBTestSupport
import Testing

@testable import BBInterfaces

@Suite("Chat interface message reader")
struct ChatMessageReaderTests {

  @Test("A message interface handed in is the one the chat interface reads through")
  func sharesTheGivenReader() throws {
    let repository = try InterfaceFixtures.repository()
    let message = MessageInterface(
      repository: repository, serializer: InterfaceFixtures.serializer)
    let chat = ChatInterface(
      repository: repository, serializer: InterfaceFixtures.serializer, messages: message)
    #expect(chat.messageReader.attachmentMetadata === message.attachmentMetadata)
  }
}
