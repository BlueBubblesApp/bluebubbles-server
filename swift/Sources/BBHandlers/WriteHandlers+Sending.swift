//  WriteHandlers+Sending
//  Sending: text, an attachment, or several parts in order.
//
//  One slice of `WriteHandlers`; the entry point that registers every slice is in
//  `WriteHandlers.swift`.

import BBDiagnostics
import BBHTTPAPI
import BBInterfaces
import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation

extension WriteHandlers {
  static func registerSending(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & UploadStoring
  ) {
    registry.register(.messageSendText) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()

      let chatGUID = try values.requireString("chatGuid")
      let message = try values.requireString("message")

      // `method` is how clients force AppleScript on a server that has the Private API.
      let forced: MessageInterface.SendBackend?
      switch values["method"]?.stringValue?.lowercased() {
      case "apple-script", "applescript": forced = .appleScript
      case "private-api", "privateapi": forced = .privateAPI
      case .some(let other): throw BadRequest("unknown send method `\(other)`")
      case nil: forced = nil
      }

      let sent = try await interfaces.message.sendText(
        MessageInterface.SendTextRequest(
          chatGUID: chatGUID,
          text: message,
          subject: values["subject"]?.stringValue,
          effectID: values["effectId"]?.stringValue,
          replyToGUID: values["selectedMessageGuid"]?.stringValue,
          partIndex: values["partIndex"]?.intValue ?? 0,
          scanForLinks: values["scanForLinks"]?.boolValue ?? false,
          // The reference's `textFormatting` (styles by range) with `effect` added.
          formatting: try TextFormattingBody.parse(values["textFormatting"]),
          forcedBackend: forced
        )
      )
      return try Self.sendResult(
        sent, interfaces: interfaces,
        tempGUID: values["tempGuid"]?.stringValue,
        checkingSendError: true
      )
    }

    registry.register(.messageSendAttachment) { request in
      let interfaces = try await context.requireInterfaces()
      // The client's form (an `attachment` part and string fields) or a JSON `filePath`
      // for a file `attachment/upload` already staged. See `UploadedFileBody`.
      let body = try UploadedFileBody.parse(
        request, filePart: "attachment", uploads: context.uploads
      )
      let values = body.values
      let chatGUID = try values.requireString("chatGuid")
      // The reference validator forces `method` to private-api when any of these is
      // present, and `sendAttachment` does the same by needing the helper for them.
      let sent = try await interfaces.message.sendAttachment(
        MessageInterface.SendAttachmentRequest(
          chatGUID: chatGUID,
          filePath: body.path,
          isAudioMessage: values.bool("isAudioMessage") ?? false,
          subject: values.string("subject"),
          effectID: values.string("effectId"),
          replyToGUID: values.string("selectedMessageGuid"),
          partIndex: values.int("partIndex")
        )
      )
      // No `tempGuid`, and no error check. The reference injects the temp GUID only on
      // text and multipart: the attachment route reads it from the body for its send cache
      // and does not echo it, and it answers 200 even for a row whose `error` is set.
      return try Self.sendResult(sent, interfaces: interfaces)
    }
  }

  static func registerMultipart(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding
  ) {
    registry.register(.messageSendMultipart) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let chatGUID = try values.requireString("chatGuid")

      // Order is the whole point of this route, so `parts` is read as an array and
      // kept in the order it arrived. A part with neither text nor an attachment is
      // rejected rather than skipped: silently dropping it would renumber every part
      // after it, and mention indices are positional.
      let parts = try (values["parts"]?.arrayValue ?? []).map { part -> MessagePart in
        let text = part["text"]?.stringValue
        let path = part["filePath"]?.stringValue ?? part["attachmentPath"]?.stringValue
        guard text != nil || path != nil else {
          throw BadRequest("every part needs `text` or `filePath`")
        }
        return MessagePart(
          text: text,
          attachmentPath: path,
          mention: part["mention"]?.stringValue,
          formatting: try TextFormattingBody.parse(part["textFormatting"])
        )
      }

      let sent = try await interfaces.message.sendMultipart(
        MessageInterface.SendMultipartRequest(
          chatGUID: chatGUID,
          parts: parts,
          subject: values["subject"]?.stringValue,
          effectID: values["effectId"]?.stringValue,
          replyToGUID: values["selectedMessageGuid"]?.stringValue,
          partIndex: values["partIndex"]?.intValue
        )
      )
      return try Self.sendResult(
        sent, interfaces: interfaces,
        tempGUID: values["tempGuid"]?.stringValue,
        checkingSendError: true
      )
    }
  }

  /// The response every send route gives: the message it wrote.
  ///
  /// **A send answers with the MESSAGE**: the serialised row, as the reference does, so a
  /// client can read back the text, date, handle and chats of what it just sent. The
  /// hydration is in `MessageInterface`.
  ///
  /// - Parameter checkingSendError: whether a non-zero `error` on the row becomes a 500.
  ///   **Only `text` and `multipart` do this.** It reads like something that should be
  ///   uniform and is not: `attachment` and `attachment/chunk` return 200 with the failed
  ///   message in `data` and let the client read `error` itself. Both are transcribed rather
  ///   than tidied: a client that has been shown a 200 for a failed attachment since the
  ///   Electron server would start seeing 500s.
  static func sendResult(
    _ outcome: MessageInterface.SendOutcome,
    interfaces: ServerInterfaces,
    tempGUID: String? = nil,
    checkingSendError: Bool = false
  ) throws -> RouteResult {
    let data = interfaces.message.serialize(outcome, tempGUID: tempGUID)

    // The shape clients depend on most: Messages can accept a send and then fail it, the
    // row records that in `error`, and the reference reports it as a 500 carrying the same
    // message. That is how a client shows a red mark against what it just sent; a 200 would
    // tell it the send worked.
    if checkingSendError, MessageInterface.sendFailed(outcome) {
      throw IMessageError(
        "Message failed to send!",
        message: "Message sent with an error. See attached message",
        data: data
      )
    }
    return .data(data)
  }
}
