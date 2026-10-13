//  PrivateAPIClient+Sending
//  The roles that put something new into a chat: `MessageSending`, `PollControl` and
//  `StickerLibrary`. Every send answers with the `SentMessage` the helper confirmed, read by
//  the one `sentMessage(from:chat:)`, so a sent GUID is decoded the same way for every kind
//  of send.
//
//  One slice of `PrivateAPIClient`; the type, its transport and the payload shapes every
//  role shares are in `PrivateAPIClient.swift`.

import BBPrivateAPIContract
import Foundation

extension PrivateAPIClient: MessageSending {

  public func sendMessage(_ request: SendMessageRequest) async throws -> SentMessage {
    let payload = WireJSON.object(dropping: [
      .chatGuid: .string(request.chat.rawValue),
      .message: .string(request.text),
      .subject: request.subject.map(WireJSON.string),
      .effectId: request.effectId.map(WireJSON.string),
      .selectedMessageGuid: request.replyTo.map { .string($0.rawValue) },
      .partIndex: .number(Double(request.replyPartIndex ?? 0)),
      // 0/1 rather than a boolean: the helper reads it as a number.
      .ddScan: .number(request.scanForLinks ? 1 : 0),
      .textFormatting: Self.wireFormatting(request.formatting),
      .scheduledFor: request.scheduledFor.map { .number(Double($0.wireMilliseconds)) },
    ])
    let result = try await transport.request(
      action: .sendMessage, data: payload)
    return try sentMessage(from: result, chat: request.chat)
  }

  public func sendMultipart(_ request: SendMultipartRequest) async throws -> SentMessage {
    let parts = request.parts.map { part in
      WireJSON.object(dropping: [
        .text: part.text.map(WireJSON.string),
        .attachment: part.attachmentPath.map(WireJSON.string),
        .mention: part.mention.map(WireJSON.string),
        .textFormatting: Self.wireFormatting(part.formatting),
      ])
    }
    let payload = WireJSON.object(dropping: [
      .chatGuid: .string(request.chat.rawValue),
      .parts: .array(parts),
      .subject: request.subject.map(WireJSON.string),
      .effectId: request.effectId.map(WireJSON.string),
      .selectedMessageGuid: request.replyTo.map { .string($0.rawValue) },
      .partIndex: .number(Double(request.replyPartIndex ?? 0)),
      // As `sendMessage`: 0/1, because the helper reads it as a number.
      .ddScan: .number(request.scanForLinks ? 1 : 0),
    ])
    let result = try await transport.request(
      action: .sendMultipart, data: payload)
    return try sentMessage(from: result, chat: request.chat)
  }

  public func sendAppMessage(_ request: SendAppMessageRequest) async throws -> SentMessage {
    let result = try await transport.request(
      action: .sendAppMessage,
      data: .object(dropping: [
        .chatGuid: .string(request.chat.rawValue),
        .balloonBundleId: .string(request.balloonBundleID),
        // Base64: the wire is JSON and the payload is an archive.
        .payload: .string(request.payload.base64EncodedString()),
        .summary: request.summary.map(WireJSON.string),
      ]))
    return try sentMessage(from: result, chat: request.chat)
  }

  public func sendAttachment(_ request: SendAttachmentRequest) async throws -> SentMessage {
    // Checked here, because the helper reports a missing file as a generic failure and
    // the caller then has no idea which path was wrong.
    guard FileManager.default.fileExists(atPath: request.filePath) else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "attachment not found at \(request.filePath)"
      )
    }
    let payload = WireJSON.object([
      .chatGuid: .string(request.chat.rawValue),
      .filePath: .string(request.filePath),
      .isAudioMessage: .number(request.isAudioMessage ? 1 : 0),
    ])
    let result = try await transport.request(
      action: .sendAttachment, data: payload)
    return try sentMessage(from: result, chat: request.chat)
  }

  public func react(_ request: ReactionRequest) async throws -> SentMessage {
    let result = try await transport.request(
      action: .sendReaction,
      data: .object(dropping: [
        .chatGuid: .string(request.chat.rawValue),
        .selectedMessageGuid: .string(request.target.rawValue),
        .reactionType: .string(request.reaction.rawValue),
        .partIndex: .number(Double(request.partIndex)),
        .reactionEmoji: request.emoji.map(WireJSON.string),
      ]))
    return try sentMessage(from: result, chat: request.chat)
  }

  public func sendSticker(_ request: SendStickerRequest) async throws -> SentMessage {
    guard FileManager.default.fileExists(atPath: request.filePath) else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "sticker not found at \(request.filePath)"
      )
    }
    let result = try await transport.request(
      action: .sendSticker,
      data: .object([
        .chatGuid: .string(request.chat.rawValue),
        .filePath: .string(request.filePath),
        .selectedMessageGuid: .string(request.target.rawValue),
        .partIndex: .number(Double(request.partIndex)),
        .xScalar: .number(request.placement.xScalar),
        .yScalar: .number(request.placement.yScalar),
        .scale: .number(request.placement.scale),
        .rotation: .number(request.placement.rotation),
        .parentPreviewWidth: .number(request.placement.parentPreviewWidth),
        .tapback: .bool(request.asTapback),
        .remove: .bool(request.isRemoval),
      ]))
    return try sentMessage(from: result, chat: request.chat)
  }

  /// `textFormatting` as the helper reads it; absent (dropped) when there is none, so a
  /// plain send's payload is byte-for-byte what it was.
  private static func wireFormatting(_ ranges: [FormattedRange]) -> WireJSON? {
    guard !ranges.isEmpty else { return nil }
    return .array(
      ranges.map { range in
        WireJSON.object(dropping: [
          .start: .number(Double(range.start)),
          .length: .number(Double(range.length)),
          .styles: .array(range.styles.map { .string($0.rawValue) }),
          .effect: range.effect.map { .string($0.rawValue) },
        ])
      })
  }
}

extension PrivateAPIClient: PollControl {

  public func createPoll(_ request: PollCreateRequest) async throws -> SentMessage {
    let result = try await transport.request(
      action: .createPoll,
      data: .object([
        .chatGuid: .string(request.chat.rawValue),
        .title: .string(request.title),
        .options: .array(request.options.map(WireJSON.string)),
      ]))
    return try sentMessage(from: result, chat: request.chat)
  }

  public func updatePoll(_ request: PollUpdateRequest) async throws -> SentMessage {
    let result = try await transport.request(
      action: .updatePoll,
      data: .object(dropping: [
        .chatGuid: .string(request.chat.rawValue),
        .rootGuid: .string(request.rootGUID.rawValue),
        .sessionId: .string(request.sessionID),
        .title: .string(request.title),
        .creatorHandle: request.creatorHandle.map(WireJSON.string),
        .options: .array(
          request.options.map { option in
            WireJSON.object(dropping: [
              .id: .string(option.id),
              .text: .string(option.text),
              .creatorHandle: option.creatorHandle.map(WireJSON.string),
              .canBeEdited: .bool(option.canBeEdited),
            ])
          }),
      ]))
    return try sentMessage(from: result, chat: request.chat)
  }

  public func votePoll(_ request: PollVoteRequest) async throws -> SentMessage {
    let result = try await transport.request(
      action: .votePoll,
      data: .object([
        .chatGuid: .string(request.chat.rawValue),
        .stateGuid: .string(request.stateGUID.rawValue),
        .sessionId: .string(request.sessionID),
        .optionIds: .array(request.optionIDs.map(WireJSON.string)),
      ]))
    return try sentMessage(from: result, chat: request.chat)
  }
}

extension PrivateAPIClient: StickerLibrary {

  public func saveSticker(_ request: SaveStickerRequest) async throws -> SavedSticker {
    guard FileManager.default.fileExists(atPath: request.filePath) else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "sticker not found at \(request.filePath)"
      )
    }
    let result = try await transport.request(
      action: .saveSticker,
      data: .object([
        .filePath: .string(request.filePath),
        .name: request.name.map(WireJSON.string) ?? .null,
        .accessibilityName: request.accessibilityName.map(WireJSON.string) ?? .null,
      ]))
    guard let identifier = result?[.identifier]?.stringValue, !identifier.isEmpty else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "the sticker store accepted the sticker but reported no identifier"
      )
    }
    return SavedSticker(
      identifier: identifier,
      externalURI: result?[.externalURI]?.stringValue ?? "",
      byteCount: Int(result?[.byteCount]?.stringValue ?? "") ?? 0
    )
  }
}
