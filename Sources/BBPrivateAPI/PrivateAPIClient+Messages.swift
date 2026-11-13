//  PrivateAPIClient+Messages
//  The roles that act on a message already in a chat: `MessageMutation`,
//  `ScheduledMessaging` and `MessageQuerying`. A mutation or a scheduling call names its
//  message by GUID and its chat together, because the helper cannot derive the chat from
//  the message (see `editMessage`).
//
//  One slice of `PrivateAPIClient`; the type, its transport and the payload shapes every
//  role shares are in `PrivateAPIClient.swift`.

import BBPrivateAPIContract
import Foundation

extension PrivateAPIClient: MessageMutation {

  /// Editing needs the chat, and the helper cannot derive it.
  ///
  /// MEASURED: an `IMMessageItem` retrieved by GUID reports `chatIdentifier = nil`, so
  /// there is nothing on the message to look a conversation up by. The chat-less form of
  /// this call is deliberately absent: it could only ever fail. The server resolves the
  /// chat from chat.db instead, which is authoritative and free.
  public func editMessage(
    _ guid: MessageGUID,
    in chat: ChatIdentifier,
    partIndex: Int,
    newText: String,
    backwardCompatibilityText: String
  ) async throws {
    try await transport.request(
      action: .editMessage,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .messageGuid: .string(guid.rawValue),
        .editedMessage: .string(newText),
        .backwardsCompatibilityMessage: .string(backwardCompatibilityText),
        .partIndex: .number(Double(partIndex)),
      ]))
  }

  public func unsendMessage(_ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int)
    async throws
  {
    try await transport.request(
      action: .unsendMessage,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .messageGuid: .string(guid.rawValue),
        .partIndex: .number(Double(partIndex)),
      ]))
  }

  public func deleteMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    try await transport.request(
      action: .deleteMessage,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .messageGuid: .string(guid.rawValue),
      ]))
  }

  public func notifyAnyways(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    try await transport.request(
      action: .notifyAnyways,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .messageGuid: .string(guid.rawValue),
      ]))
  }
}

extension PrivateAPIClient: ScheduledMessaging {

  public func editScheduledMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int, newText: String
  ) async throws {
    _ = try await transport.request(
      action: .editScheduledMessage,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .messageGuid: .string(guid.rawValue),
        .partIndex: .number(Double(partIndex)),
        .editedMessage: .string(newText),
      ]))
  }

  public func rescheduleMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, to date: Date
  ) async throws {
    _ = try await transport.request(
      action: .rescheduleMessage,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .messageGuid: .string(guid.rawValue),
        .scheduledFor: .number(Double(date.wireMilliseconds)),
      ]))
  }

  public func sendScheduledMessageNow(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    _ = try await transport.request(
      action: .sendScheduledNow,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .messageGuid: .string(guid.rawValue),
      ]))
  }

  public func cancelScheduledMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    _ = try await transport.request(
      action: .cancelScheduledMessage,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .messageGuid: .string(guid.rawValue),
      ]))
  }
}

extension PrivateAPIClient: MessageQuerying {

  public func searchMessages(_ request: MessageSearchRequest) async throws -> [MessageGUID] {
    let result = try await transport.request(
      action: .searchMessages,
      data: .object([
        .query: .string(request.query),
        .matchType: .string("contains"),
      ]))
    return try WireReader(reply: result, to: .searchMessages).strings(.results)
      .map { MessageGUID($0) }
  }

  public func balloonBundleMediaPath(for guid: MessageGUID) async throws -> String? {
    let result = try await transport.request(
      action: .balloonBundleMediaPath,
      data: .object([.messageGuid: .string(guid.rawValue)])
    )
    // No `path` is the helper saying the message has none; see the contract.
    guard let path = result?[.path]?.stringValue ?? result?.stringValue, !path.isEmpty else {
      return nil
    }
    return path
  }
}
