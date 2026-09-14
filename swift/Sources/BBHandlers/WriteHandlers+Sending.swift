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
    context: some InterfaceProviding & UploadStoring & SendDeduplicating
  ) {
    registry.register(.messageSendText) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()

      // One `tempGuid`, one send. See `SendCache`: the hydration wait holds this response
      // for up to a minute, which is long enough that a client times out and retries, and
      // the retry used to put a second message in somebody's conversation.
      let tempGUID = values["tempGuid"]?.stringValue
      return try await Self.deduplicating(tempGUID, on: context.sendCache) {
        let chatGUID = try values.requireString("chatGuid")

        // PRESENT, not non-empty. The reference's rule is `message: "present|string"`
        // (`validators/messageValidator.ts:74`): the key has to be there, and an empty string
        // satisfies it. Whether the text may actually be empty is decided below, by the
        // backend, because the two backends differ.
        //
        // This was `requireString`, which rejects empty as well as absent, and that was a
        // break against shipped clients rather than a stricter reading: a subject-only send
        // (`message: ""` with a subject) is answered 200 by the reference and was answered
        // 400 here.
        guard let message = values["message"]?.stringValue else {
          throw BadRequest(RequestValues.missing("message"))
        }

        // `method` is how clients force AppleScript on a server that has the Private API.
        let forced: MessageInterface.SendBackend?
        switch values["method"]?.stringValue?.lowercased() {
        case "apple-script", "applescript": forced = .appleScript
        case "private-api", "privateapi": forced = .privateAPI
        case .some(let other): throw BadRequest("unknown send method `\(other)`")
        case nil: forced = nil
        }

        let subject = values["subject"]?.stringValue
        let effectID = values["effectId"]?.stringValue
        let replyToGUID = values["selectedMessageGuid"]?.stringValue
        let formatting = try TextFormattingBody.parse(values["textFormatting"])

        // Which backend the emptiness rule is judged against, following
        // `messageValidator.ts:87-103`: the default is AppleScript, and any of these fields
        // IMPLIES the Private API because AppleScript cannot carry them. This is the
        // validator's own resolution, which is deliberately not the same as the one the send
        // path later makes: this one decides what a client is allowed to ask for, and
        // `MessageSending` decides what this server can actually do about it.
        let impliesPrivateAPI =
          subject != nil || effectID != nil || replyToGUID != nil
          || values["ddScan"] != nil || values["attributedBody"] != nil || !formatting.isEmpty
        let judgedBackend =
          impliesPrivateAPI
          ? MessageInterface.SendBackend.privateAPI
          : (forced ?? .appleScript)

        switch judgedBackend {
        case .appleScript:
          guard !message.isEmpty else {
            throw BadRequest("A 'message' is required when sending via AppleScript")
          }
        case .privateAPI:
          // Either one carries the send. The reference's own wording, because a client that
          // surfaces the error has been showing this sentence.
          guard !message.isEmpty || !(subject ?? "").isEmpty else {
            throw BadRequest(
              "A 'message' or 'subject' is required when sending via the Private API"
            )
          }
        }

        let sent = try await interfaces.message.sendText(
          MessageInterface.SendTextRequest(
            chatGUID: chatGUID,
            text: message,
            subject: subject,
            effectID: effectID,
            replyToGUID: replyToGUID,
            partIndex: try values.wholeNumber("partIndex") ?? 0,
            scanForLinks: values["scanForLinks"]?.boolValue ?? false,
            // The reference's `textFormatting` (styles by range) with `effect` added.
            formatting: formatting,
            forcedBackend: forced
          )
        )
        return try Self.sendResult(
          sent, interfaces: interfaces,
          tempGUID: tempGUID,
          checkingSendError: true
        )
      }
    }

    registry.register(.messageSendAttachment) { request in
      let interfaces = try await context.requireInterfaces()
      // The client's form (an `attachment` part and string fields) or a JSON `filePath`
      // for a file `attachment/upload` already staged. See `UploadedFileBody`.
      let body = try UploadedFileBody.parse(
        request, filePart: "attachment", uploads: context.uploads
      )
      let values = body.values
      let tempGUID = values.string("tempGuid")
      return try await Self.deduplicating(tempGUID, on: context.sendCache) {
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
            partIndex: try values.wholeNumber("partIndex")
          )
        )
        // No `tempGuid`, and no error check. The reference injects the temp GUID only on
        // text and multipart: the attachment route reads it from the body for its send cache
        // and does not echo it, and it answers 200 even for a row whose `error` is set.
        return try Self.sendResult(sent, interfaces: interfaces)
      }
    }
  }

  static func registerMultipart(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & SendDeduplicating
  ) {
    registry.register(.messageSendMultipart) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()

      let tempGUID = values["tempGuid"]?.stringValue
      return try await Self.deduplicating(tempGUID, on: context.sendCache) {
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
            partIndex: try values.wholeNumber("partIndex")
          )
        )
        return try Self.sendResult(
          sent, interfaces: interfaces,
          tempGUID: tempGUID,
          checkingSendError: true
        )
      }
    }
  }

  /// Runs a send under a `tempGuid` claim, releasing it however the send ends.
  ///
  /// A wrapper rather than `defer { Task { await release() } }`, which is the shape this was
  /// written as first: that releases AFTER the handler has returned, on a task nobody waits
  /// for, so there is a window where the client has its answer and the claim is still held.
  /// It is a microscopic window and it is avoidable, and an `async` release that the caller
  /// awaits on both paths has no window at all.
  ///
  /// The failure path releases too, deliberately: a send that failed is one the client
  /// SHOULD retry, and holding the claim would turn one failure into two minutes of
  /// refusals.
  static func deduplicating<Result>(
    _ tempGUID: String?,
    on cache: SendCache,
    _ send: () async throws -> Result
  ) async throws -> Result {
    guard await cache.claim(tempGUID) else { throw alreadySending(tempGUID) }
    do {
      let result = try await send()
      await cache.release(tempGUID)
      return result
    } catch {
      await cache.release(tempGUID)
      throw error
    }
  }

  /// The refusal a duplicate gets, in the reference's own words.
  ///
  /// Its socket path answers exactly this sentence for a `tempGuid` already in the send
  /// cache (`socketRoutes.ts:536-541`); the HTTP surface it never checked on is where this
  /// server's clients actually send, so the sentence moves there rather than being invented.
  static func alreadySending(_ tempGUID: String?) -> BadRequest {
    BadRequest("Message is already queued to be sent (Temp GUID: \(tempGUID ?? ""))!")
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
