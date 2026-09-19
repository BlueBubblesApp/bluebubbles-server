//  IMCoreBridge+Sending
//  Putting something new into a conversation: text, multipart, attachments, tapbacks,
//  stickers and iMessage-app balloons. `MessageSending`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  /// `associatedMessageType` values that are not tapbacks. The tapback ones live on
  /// `ReactionType` in the contract because a client names them; these are only ever
  /// chosen here.
  ///
  /// From `_sendCommSafetyVerifiedSticker:…`: `mov w8, #1000; cinc x27, x8, isEmojiSticker`:
  /// 1000 for a sticker, 1001 for an emoji sticker. chat.db agrees: every received
  /// sticker on this Mac is 1000, and the reference serialises 1000 as `"sticker"`.
  private enum AssociatedMessageType {
    static let sticker: Int64 = 1000
  }

  /// The target part of a reply, loaded ahead of the synchronous send block.
  private func replyPart(for target: MessageGUID?, partIndex: Int?) async throws -> AnyObject? {
    guard let target else { return nil }
    return try await IMChatHistory.messagePartChatItem(
      guid: target.rawValue, partIndex: partIndex ?? 0
    )
  }

  /// PORTED. ObjC: `sendMessage:transfers:attributedString:transaction:`
  /// (BlueBubblesHelper.m:1013).
  public func sendMessage(_ request: SendMessageRequest) async throws -> SentMessage {
    // Reply threading. IMCore has no reply parameter: a reply is an ordinary message
    // whose threadIdentifier names the THREAD it joins, resolved from the target part (see
    // `IMThreads`). Only the part is loaded here, because that is asynchronous; the thread
    // is read off it inside the block, with no suspension before the send.
    let replyPart = try await replyPart(for: request.replyTo, partIndex: request.replyPartIndex)
    return try translating {
      let chat = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
      let reply = try replyPart.map(IMThreads.reply(for:))

      // Send Later goes through ChatKit, because that is the only path that files a
      // message as scheduled; see `CKCompositions.setSendLater`, which records what
      // happens when you try it the other way.
      if let scheduledFor = request.scheduledFor {
        return try sendScheduled(request, at: scheduledFor, reply: reply)
      }

      // Styles and effects are attributes on the text itself; the initializer takes an
      // attributed string and imagent stores whatever it carries. See
      // `TextFormattingAttributes`.
      let text = NSMutableAttributedString(string: request.text)
      TextFormattingAttributes.apply(request.formatting, to: text)
      let message = try IMMessageBuilder.message(
        text: text,
        subject: request.subject.map { NSAttributedString(string: $0) },
        fileTransferGUIDs: [],
        effectID: request.effectId,
        threadIdentifier: reply?.identifier,
        isAudioMessage: false
      )
      if let originator = reply?.originator {
        _ = try? IMCoreRuntime.invoke(message, "setThreadOriginator:", [originator])
      }
      try chat.send(message)

      // Read AFTER the send: `sendMessage:` returns nothing, and the GUID does not
      // exist until Messages has accepted the message.
      guard let guid = try chat.lastSentMessageGUID() else {
        throw PrivateAPIErrorShim.rejected(
          "Messages accepted the send but reported no message GUID"
        )
      }
      // `sentAt` is when WE observed the send, not what Messages will eventually
      // record: that timestamp is assigned by the daemon and only appears in chat.db.
      // The server reads the authoritative one from there; this is for correlation.
      return SentMessage(
        guid: MessageGUID(guid), chat: request.chat, sentAt: Date()
      )
    }
  }

  /// PORTED. ObjC: `sendMessageToChat:` (BlueBubblesHelper.m:1008), the ChatKit path.
  ///
  /// Parts append in order, so text and attachments interleave as the caller asked. One
  /// synchronous block for the same reason as `sendAttachment`.
  public func sendMultipart(_ request: SendMultipartRequest) async throws -> SentMessage {
    // As `sendMessage`: the part is loaded first, the thread read off it inside the block.
    let replyPart = try await replyPart(for: request.replyTo, partIndex: request.replyPartIndex)
    return try translating {
      let conversation = try requireConversation(request.chat)
      let reply = try replyPart.map(IMThreads.reply(for:))

      var composition = try CKCompositions.empty(
        subject: request.subject.map { NSAttributedString(string: $0) }
      )
      for part in request.parts {
        if let path = part.attachmentPath, !path.isEmpty {
          composition = try CKCompositions.appendingMedia(composition, path: path)
        } else if let text = part.text, !text.isEmpty {
          composition = try CKCompositions.appendingText(
            composition, text: text, mention: part.mention, formatting: part.formatting
          )
        }
      }
      CKCompositions.setEffect(composition, request.effectId)

      guard conversation.canSend(composition) else {
        throw PrivateAPIErrorShim.rejected("ChatKit will not send this composition")
      }

      let messages = try conversation.messages(from: composition)
      for message in messages {
        if let reply {
          try IMCoreRuntime.invoke(message, "setThreadIdentifier:", [reply.identifier])
          if let originator = reply.originator {
            _ = try? IMCoreRuntime.invoke(message, "setThreadOriginator:", [originator])
          }
        }
        try conversation.send(message)
      }
      let guid =
        messages.first
        .flatMap { ((try? IMCoreRuntime.string($0, "guid")) ?? nil) } ?? ""
      return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
    }
  }

  /// PORTED. ObjC: `sendMessageToChat:` (BlueBubblesHelper.m:1008), the ChatKit path.
  ///
  /// **One synchronous block, with no suspension between building the composition and
  /// sending it.** The reference does the whole sequence inside a single Objective-C
  /// method, and matching that is not stylistic: `BBInvoke` hands objects back
  /// AUTORELEASED (`*outResult` is `__autoreleasing`), and a Swift `await` drains the
  /// enclosing pool. The `CKMediaObject` holds a live `CKIMFileTransfer` that is still
  /// preparing (`isFileDataReady:0`) so a suspension in the middle is exactly where that
  /// graph can be torn down, leaving a message that sends with a transfer GUID and no
  /// bytes behind it.
  ///
  /// The IMCore alternative is not available as a fallback: its staging path is
  /// sandbox-blocked on modern macOS. See the note at the end of this file.
  public func sendAttachment(_ request: SendAttachmentRequest) async throws -> SentMessage {
    try translating {
      let conversation = try requireConversation(request.chat)

      let composition: AnyObject =
        request.isAudioMessage
        ? try CKCompositions.audio(path: request.filePath)
        : try CKCompositions.appendingMedia(
          try CKCompositions.empty(subject: nil), path: request.filePath
        )

      guard conversation.canSend(composition) else {
        throw PrivateAPIErrorShim.rejected(
          "ChatKit will not send this composition; the attachment may be an "
            + "unsupported type, or too large for this conversation's service"
        )
      }

      let messages = try conversation.messages(from: composition)
      for message in messages { try conversation.send(message) }

      let guid =
        messages.first
        .flatMap { ((try? IMCoreRuntime.string($0, "guid")) ?? nil) } ?? ""
      return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
    }
  }

  /// PORTED. ObjC: the association initializer plus `[chat sendMessage:]`
  /// (BlueBubblesHelper.m:1053).
  public func react(_ request: ReactionRequest) async throws -> SentMessage {
    // Messages' own path (`IMTapbacks`) wants the target PART chat item; loaded first
    // because that is asynchronous, used inside the block with no suspension after.
    //
    // BOTH halves are asked for, and that is the fix for the Sonoma reaction bug: the
    // sender being present does not mean the tapback object can be built. On macOS 14
    // `IMTapbackSender` is there and `+[IMTapback tapbackWithAssociatedMessageType:]` is
    // not, so asking only the first sent every reaction down a path that then threw, with
    // a working fallback sitting directly below. `docs/SONOMA_COMPATIBILITY.md` §2.1.
    let useMessagesPath = IMTapbacks.senderAvailable && IMTapbacks.canBuild(request.reaction)
    let part: AnyObject? =
      useMessagesPath
      ? try await IMChatHistory.messagePartChatItem(
        guid: request.target.rawValue, partIndex: request.partIndex)
      : nil
    return try translating {
      let chat = try IMChatRegistry.requireChat(guid: request.chat.rawValue)

      if let part {
        let tapback = try IMTapbacks.tapback(request.reaction, emoji: request.emoji)
        let sent = try IMTapbacks.send(tapback, chat: chat, part: part)
        var guid = sent.flatMap { ((try? IMCoreRuntime.string($0, "guid")) ?? nil) }
        if guid == nil { guid = try chat.lastSentMessageGUID() }
        guard let guid else {
          throw PrivateAPIErrorShim.rejected(
            "Messages accepted the reaction but reported no message GUID")
        }
        return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
      }

      // Fallback for a macOS that cannot take the Messages path: the association
      // initializer. It is how the shipping ObjC helper has always sent the six named
      // tapbacks, and on macOS 14 it is the only way, but it writes the reaction into an
      // `associatedMessageType`, and there is no such number for "emoji", so an emoji
      // reaction genuinely cannot come this way.
      guard !request.reaction.isEmoji else {
        throw PrivateAPIError.unavailableOnThisOS(
          method: "react(_:)", requires: "IMEmojiTapback (macOS 15 or later)")
      }
      // A tapback still carries text, and IMCore rejects an empty one: the shipping
      // helper substitutes "TEMP" for exactly this reason (BlueBubblesHelper.m:1024).
      // The text is never displayed; the association is what renders.
      let message = try IMMessageBuilder.association(
        text: NSAttributedString(string: "TEMP"),
        associatedGUID: request.target.rawValue,
        associatedType: request.reaction.associatedMessageType,
        // The part of the message being reacted to. Location is the part index and
        // length is 1: a tapback attaches to one part, not a character range.
        range: NSRange(location: request.partIndex, length: 1),
        summaryInfo: nil
      )
      try chat.send(message)

      // Read AFTER the send, exactly as `sendMessage` does: a tapback goes out through
      // `chat.send` like any other message, so the GUID does not exist until Messages has
      // accepted it and `lastSentMessage` is where it appears.
      guard let guid = try chat.lastSentMessageGUID() else {
        throw PrivateAPIErrorShim.rejected(
          "Messages accepted the reaction but reported no message GUID"
        )
      }
      return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
    }
  }

  /// NEW: no Objective-C counterpart; the shipping helper never sent stickers.
  ///
  /// Transcribed from Messages' own drag-and-drop send on macOS 26.5.2 instead:
  /// `-[CKChatController sendSticker:withDragTarget:draggedSticker:]` down to
  /// `_sendCommSafetyVerifiedSticker:…` (disassembled; `docs/PRIVATE_API_SURFACE.md`
  /// § Stickers has the chain). The parts are the ones `IMStickers` documents; what this
  /// method adds is the ORDER, and two things the tapback path does differently.
  ///
  /// The parent part is loaded FIRST and asynchronously, because it comes from
  /// `IMChatHistoryController` and that is a completion-block load. Everything from the
  /// sticker object to the send then runs in ONE synchronous block, for the reason
  /// `sendAttachment` gives: the media object holds a live transfer that is still
  /// preparing, and a suspension between building it and sending is where that graph
  /// gets torn down.
  ///
  /// `newComposition:NO`: Messages passes NO for a sticker where it passes YES for a
  /// typed message. The flag tells ChatKit whether the send came from the compose field
  /// (and so whether to clear it), and a sticker does not.
  public func sendSticker(_ request: SendStickerRequest) async throws -> SentMessage {
    let part = try await IMChatHistory.messagePartChatItem(
      guid: request.target.rawValue, partIndex: request.partIndex
    )
    return try translating {
      // A sticker TAPBACK is a tapback that renders a sticker: same media object and
      // transfer, but the message comes from `IMStickerTapback` through `IMTapbackSender`
      // rather than being built here. Messages positions it, so `placement` is unused.
      if request.asTapback {
        // Two classes, and naming the one that is actually missing is the difference
        // between a report that leads somewhere and one that sends the reader to the
        // wrong release. `IMTapbackSender` is present as far back as macOS 14;
        // `IMStickerTapback` arrived in 15; measured on 14.6.1, 15.6.1 and 26.5.2, not
        // guessed, which is the only reason this names a version at all.
        guard IMTapbacks.senderAvailable else {
          throw PrivateAPIError.unavailableOnThisOS(
            method: "sticker tapback", requires: "IMTapbackSender")
        }
        guard IMCoreRuntime.lookUpClass("IMStickerTapback") != nil else {
          throw PrivateAPIError.unavailableOnThisOS(
            method: "sticker tapback", requires: "IMStickerTapback (macOS 15 or later)")
        }
        let chat = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
        let sticker = try IMStickers.sticker(path: request.filePath)
        let userInfo = try IMStickers.userInfo(placement: request.placement)
        let media = try IMStickers.mediaObject(sticker: sticker, userInfo: userInfo)
        guard let transferGUID = try IMCoreRuntime.string(media, "transferGUID"),
          !transferGUID.isEmpty
        else {
          throw PrivateAPIErrorShim.rejected("the sticker's media object has no transfer GUID")
        }
        let tapback = try IMTapbacks.stickerTapback(
          transferGUID: transferGUID, isRemoved: request.isRemoval)
        let sent = try IMTapbacks.send(tapback, chat: chat, part: part)
        var guid = sent.flatMap { ((try? IMCoreRuntime.string($0, "guid")) ?? nil) }
        if guid == nil { guid = try chat.lastSentMessageGUID() }
        guard let guid else {
          throw PrivateAPIErrorShim.rejected(
            "Messages accepted the sticker tapback but reported no GUID")
        }
        return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
      }

      let conversation = try requireConversation(request.chat)

      // The chat item's GUID is "p:<part>/<message guid>", and that prefix is what tells
      // every device which balloon the sticker sits on. The bare message GUID renders
      // nothing.
      guard let partGUID = try IMCoreRuntime.string(part, "guid"), !partGUID.isEmpty else {
        throw PrivateAPIErrorShim.rejected("that message part has no chat item GUID")
      }
      let range = try IMStickers.partRange(part)
      let threadIdentifier = (try? IMCoreRuntime.string(part, "threadIdentifier")) ?? nil

      let sticker = try IMStickers.sticker(path: request.filePath)
      let userInfo = try IMStickers.userInfo(placement: request.placement)
      let media = try IMStickers.mediaObject(sticker: sticker, userInfo: userInfo)
      let composition = try IMStickers.composition(media: media)

      guard conversation.canSend(composition) else {
        throw PrivateAPIErrorShim.rejected(
          "ChatKit will not send this sticker; the file may be an unsupported type, or "
            + "this conversation's service cannot carry stickers"
        )
      }

      let text = try IMStickers.superFormatText(composition)
      guard let transferGUID = try IMCoreRuntime.string(media, "transferGUID"),
        !transferGUID.isEmpty
      else {
        throw PrivateAPIErrorShim.rejected("the sticker's media object has no transfer GUID")
      }

      let guid = UUID().uuidString
      let message = try IMMessageBuilder.sticker(
        text: text,
        fileTransferGUIDs: [transferGUID],
        guid: guid,
        associatedGUID: partGUID,
        associatedType: AssociatedMessageType.sticker,
        range: range,
        summaryInfo: nil,
        threadIdentifier: threadIdentifier
      )

      // Messages ties the transfer to the message before sending, and the transfer's
      // progress reporting keys off it. Best effort: a transfer class without the setter
      // still sends, it just cannot be looked up from the message afterwards.
      if let transfer = try? IMCoreRuntime.send(media, "transfer"),
        IMCoreRuntime.responds(transfer, to: NSSelectorFromString("setIMMessage:"))
      {
        _ = try? IMCoreRuntime.invoke(transfer, "setIMMessage:", [message])
      }

      try conversation.send(message, newComposition: false)

      let sentGUID = ((try? IMCoreRuntime.string(message, "guid")) ?? nil) ?? guid
      return SentMessage(guid: MessageGUID(sentGUID), chat: request.chat, sentAt: Date())
    }
  }

  /// A Send Later message: a ChatKit composition carrying the delivery date.
  ///
  /// Synchronous and called from inside `sendMessage`'s `translating` block, so the
  /// composition and the send are not separated by a suspension.
  func sendScheduled(
    _ request: SendMessageRequest, at date: Date, reply: IMThreads.Reply?
  ) throws -> SentMessage {
    let conversation = try requireConversation(request.chat)
    var composition = try CKCompositions.empty(
      subject: request.subject.map { NSAttributedString(string: $0) }
    )
    composition = try CKCompositions.appendingText(
      composition, text: request.text, mention: nil, formatting: request.formatting
    )
    CKCompositions.setEffect(composition, request.effectId)
    try CKCompositions.setSendLater(composition, date)

    guard conversation.canSend(composition) else {
      throw PrivateAPIErrorShim.rejected(
        "ChatKit will not send this composition; this conversation may not support "
          + "Send Later"
      )
    }
    let messages = try conversation.messages(from: composition)
    for message in messages {
      if let reply {
        _ = try? IMCoreRuntime.invoke(message, "setThreadIdentifier:", [reply.identifier])
        if let originator = reply.originator {
          _ = try? IMCoreRuntime.invoke(message, "setThreadOriginator:", [originator])
        }
      }
      try conversation.send(message)
    }
    let guid =
      messages.first.flatMap { ((try? IMCoreRuntime.string($0, "guid")) ?? nil) } ?? ""
    return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
  }

  /// NEW. An app balloon whose payload the SERVER built (`AppMessagePayload.encode`).
  ///
  /// Straight down IMCore rather than through ChatKit: `+[CKComposition
  /// compositionWithMSMessage:appExtensionIdentifier:]` resolves the extension through the
  /// balloon plugin manager, and a Mac usually does not have the extension installed: Game
  /// Pigeon is iOS-only. The `IMMessage` initializer already takes `balloonBundleID:` and
  /// `payloadData:`, which is all a balloon needs; the receiving device renders it.
  public func sendAppMessage(_ request: SendAppMessageRequest) async throws -> SentMessage {
    try translating {
      let chat = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
      let message = try IMMessageBuilder.appMessage(
        balloonBundleID: request.balloonBundleID,
        payload: request.payload,
        summary: request.summary
      )
      try chat.send(message)
      var guid = ((try? IMCoreRuntime.string(message, "guid")) ?? nil)
      if guid == nil || guid?.isEmpty == true { guid = try chat.lastSentMessageGUID() }
      guard let guid else {
        throw PrivateAPIErrorShim.rejected(
          "Messages accepted the app message but reported no GUID")
      }
      return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
    }
  }
}
