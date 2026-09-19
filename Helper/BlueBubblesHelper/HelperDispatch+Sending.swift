//  HelperDispatch+Sending
//  Sending: text, multipart, app messages, attachments and reactions.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func sendMessage(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    let sent = try await bridge.sendMessage(
      SendMessageRequest(
        chat: try data.chat(),
        text: try data.string(.message),
        subject: data.optionalString(.subject),
        effectId: data.optionalString(.effectId),
        replyTo: data.optionalString(.selectedMessageGuid).map(MessageGUID.init(_:)),
        replyPartIndex: data[.partIndex]?.intValue,
        scanForLinks: data.flag(.ddScan),
        formatting: data.formatting(data[.textFormatting]),
        // Epoch MILLISECONDS, the unit every date on this wire uses.
        scheduledFor: data[.scheduledFor]?.doubleValue.map {
          Date(timeIntervalSince1970: $0 / 1000)
        }
      )
    )
    return [.identifier: sent.guid.rawValue]
  }

  @MainActor
  static func sendMultipart(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    let parts = (data[.parts]?.arrayValue ?? []).map { part -> MessagePart in
      guard case .object(let fields) = part else { return MessagePart() }
      return MessagePart(
        text: fields[.text]?.stringValue,
        attachmentPath: fields[.attachment]?.stringValue,
        mention: fields[.mention]?.stringValue,
        formatting: data.formatting(fields[.textFormatting])
      )
    }
    let sent = try await bridge.sendMultipart(
      SendMultipartRequest(
        chat: try data.chat(),
        parts: parts,
        subject: data.optionalString(.subject),
        effectId: data.optionalString(.effectId),
        replyTo: data.optionalString(.selectedMessageGuid).map(MessageGUID.init(_:)),
        replyPartIndex: data[.partIndex]?.intValue
      )
    )
    return [.identifier: sent.guid.rawValue]
  }

  @MainActor
  static func sendAppMessage(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    guard let payload = data[.payload]?.stringValue.flatMap({ Data(base64Encoded: $0) })
    else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "send-app-message requires 'payload' as base64")
    }
    let sent = try await bridge.sendAppMessage(
      SendAppMessageRequest(
        chat: try data.chat(), balloonBundleID: try data.string(.balloonBundleId),
        payload: payload, summary: data.optionalString(.summary)))
    return [.identifier: sent.guid.rawValue]
  }

  @MainActor
  static func sendAttachment(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    let sent = try await bridge.sendAttachment(
      SendAttachmentRequest(
        chat: try data.chat(),
        filePath: try data.string(.filePath),
        isAudioMessage: data.flag(.isAudioMessage)
      )
    )
    return [.identifier: sent.guid.rawValue]
  }

  @MainActor
  static func sendReaction(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    guard let reaction = ReactionType(rawValue: try data.string(.reactionType)) else {
      throw PrivateAPIError.rejectedByMessages(reason: "unknown reaction type")
    }
    let reacted = try await bridge.react(
      ReactionRequest(
        chat: try data.chat(),
        target: try data.message(.selectedMessageGuid),
        reaction: reaction,
        partIndex: data.integer(.partIndex),
        // The Objective-C helper's own key for it.
        emoji: data.optionalString(.reactionEmoji)
      )
    )
    return [.identifier: reacted.guid.rawValue]
  }
}
