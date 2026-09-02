//  WriteHandlers
//  Controllers for everything that changes state in Messages.
//
//  Most of these need the Private API, and the route table already declares that with
//  `requires: .privateAPI` so the middleware rejects them before a handler runs. The
//  exceptions are the send routes: AppleScript is a supported fallback, not a degraded mode,
//  and `MessageInterface` picks between the two. See `.claude/docs/imessage.md`.

import BBDiagnostics
import BBHTTPAPI
import BBInterfaces
import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation

public enum WriteHandlers {

  public static func register(
    into registry: inout HandlerRegistry, context: some AlertProviding & InterfaceProviding
  ) {
    registerSending(into: &registry, context: context)
    registerMultipart(into: &registry, context: context)
    registerMessageActions(into: &registry, context: context)
    registerChatActions(into: &registry, context: context)
  }

  // MARK: - Sending

  private static func registerSending(
    into registry: inout HandlerRegistry, context: some AlertProviding & InterfaceProviding
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
          forcedBackend: forced
        )
      )
      return .data(sent)
    }

    registry.register(.messageSendAttachment) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let chatGUID = try values.requireString("chatGuid")
      // A path, not bytes. Multipart upload lands the file first; this sends what is
      // already on disk, which is what keeps a 500 MB video out of the heap.
      let path = try values.requireString("filePath", or: "path")
      return .data(
        try await interfaces.message.sendAttachment(
          chatGUID: chatGUID,
          filePath: path,
          isAudioMessage: values["isAudioMessage"]?.boolValue ?? false
        ))
    }
  }

  private static func registerMultipart(
    into registry: inout HandlerRegistry, context: some AlertProviding & InterfaceProviding
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
          mention: part["mention"]?.stringValue
        )
      }

      return .data(
        try await interfaces.message.sendMultipart(
          chatGUID: chatGUID,
          parts: parts,
          subject: values["subject"]?.stringValue,
          effectID: values["effectId"]?.stringValue,
          replyToGUID: values["selectedMessageGuid"]?.stringValue,
          partIndex: values["partIndex"]?.intValue
        ))
    }
  }

  // MARK: - Message actions

  private static func registerMessageActions(
    into registry: inout HandlerRegistry, context: some AlertProviding & InterfaceProviding
  ) {
    registry.register(.messageReact) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      guard let chatGUID = values["chatGuid"]?.stringValue,
        let target = values["selectedMessageGuid"]?.stringValue,
        let reaction = values["reaction"]?.stringValue
      else {
        throw BadRequest("`chatGuid`, `selectedMessageGuid` and `reaction` are required")
      }
      try await interfaces.message.react(
        chatGUID: chatGUID,
        targetGUID: target,
        reaction: reaction,
        partIndex: values["partIndex"]?.intValue ?? 0
      )
      return .data(nil)
    }

    registry.register(.messageEdit) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let values = try request.values()
      let text = try values.requireString("editedMessage")
      try await interfaces.message.edit(
        guid: guid,
        partIndex: values["partIndex"]?.intValue ?? 0,
        newText: text,
        // What a recipient on an older OS sees, since they cannot render an edit.
        // Defaulted rather than required: clients that omit it still work, and the
        // fallback text is what the current server uses.
        backwardCompatibilityText: values["backwardsCompatMessage"]?.stringValue
          ?? "Edited to \u{201C}\(text)\u{201D}"
      )
      return .data(nil)
    }

    registry.register(.messageUnsend) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let values = try request.values()
      try await interfaces.message.unsend(
        guid: guid, partIndex: values["partIndex"]?.intValue ?? 0
      )
      return .data(nil)
    }

    registry.register(.messageNotify) { request in
      let interfaces = try await context.requireInterfaces()
      try await interfaces.message.notify(guid: try request.requirePathParameter("guid"))
      return .data(nil)
    }

    registry.register(.messageEmbeddedMedia) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let path = try await interfaces.message.embeddedMediaPath(guid: guid)
      return .file(
        path: path,
        filename: (path as NSString).lastPathComponent,
        contentType: FileTypes.mimeType(for: path)
      )
    }
  }

  // MARK: - Chat actions

  /// When a mute should lift, from whichever form the client sent.
  ///
  /// Three accepted spellings, and the ABSENCE of all three means indefinitely — which is
  /// the common case ("Hide Alerts") and should not require a magic value:
  ///
  ///   - `mutedUntil`: epoch milliseconds, matching every other timestamp on this API, or
  ///     an ISO 8601 string, because half the clients that talk to this server send those
  ///     and rejecting them buys nothing.
  ///   - `durationSeconds`: relative, computed against the SERVER's clock. This exists
  ///     because a phone with a skewed clock computing an absolute instant is how a
  ///     one-hour mute becomes a mute that already expired.
  ///   - `indefinite: true`: explicit, for a client that would rather say so.
  /// A number in whichever case it arrived as. `JSONValue` distinguishes `.int`, `.int64`
  /// and `.double`, and a client sending `3600` and one sending `3600.0` mean the same
  /// thing — reading only one case is how a valid request becomes a 400.
  private static func number(_ value: JSONValue?) -> Double? {
    switch value {
    case .int(let number): Double(number)
    case .int64(let number): Double(number)
    case .double(let number): number
    default: nil
    }
  }

  private static func muteExpiry(_ body: JSONValue) throws -> Date? {
    if body["indefinite"]?.boolValue == true { return nil }

    if let seconds = Self.number(body["durationSeconds"]) {
      guard seconds > 0 else {
        throw BadRequest("`durationSeconds` must be greater than zero")
      }
      return Date().addingTimeInterval(seconds)
    }

    guard let raw = body["mutedUntil"], raw != .null else { return nil }
    if let milliseconds = Self.number(raw) {
      return Date(timeIntervalSince1970: milliseconds / 1000)
    }
    if let text = raw.stringValue, let parsed = WireDate.parse(text) {
      return parsed
    }
    throw BadRequest(
      "`mutedUntil` must be epoch milliseconds or an ISO 8601 date"
    )
  }

  private static func registerChatActions(
    into registry: inout HandlerRegistry, context: some AlertProviding & InterfaceProviding
  ) {
    registry.register(.chatCreate) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let addresses = values["addresses"]?.arrayValue?.compactMap(\.stringValue) ?? []
      let guid = try await interfaces.chat.create(
        addresses: addresses,
        service: values["service"]?.stringValue ?? "iMessage",
        message: values["message"]?.stringValue
      )
      return .data(.object(["guid": .string(guid)]))
    }

    registry.register(.chatDelete) { request in
      let interfaces = try await context.requireInterfaces()
      try await interfaces.chat.delete(guid: try request.requirePathParameter("guid"))
      return .data(nil)
    }

    registry.register(.chatLeave) { request in
      let interfaces = try await context.requireInterfaces()
      try await interfaces.chat.leave(guid: try request.requirePathParameter("guid"))
      return .data(nil)
    }

    registry.register(.chatPinned) { request in
      let interfaces = try await context.requireInterfaces()
      let chats = try await interfaces.chat.pinned(
        query: ChatInterface.Query(
          withParticipants: !request.has("with") || request.wants("participant"),
          withLastMessage: request.wants("lastmessage")
        )
      )
      // No `total` — the list IS the total, and there is no paging on a handful of
      // pins. `count` is still reported so the shape matches every other collection.
      return .data(
        .array(interfaces.chat.serialize(chats)),
        metadata: .object(["count": .int(chats.count)]))
    }

    // Two handlers over one call, so the pinned flag lives in the route rather than in
    // a body a client can omit.
    for (name, pinned): (HandlerID, Bool) in [(.chatPin, true), (.chatUnpin, false)] {
      registry.register(name) { request in
        let interfaces = try await context.requireInterfaces()
        try await interfaces.chat.setPinned(
          guid: try request.requirePathParameter("guid"), pinned: pinned
        )
        return .data(nil)
      }
    }

    // MARK: Mute
    //
    // Three routes over one piece of state, each answering with the RESULTING state so a
    // client never has to read back to find out what it did.

    registry.register(.chatMuteState) { request in
      let interfaces = try await context.requireInterfaces()
      let state = try await interfaces.chat.muteState(
        guid: try request.requirePathParameter("guid")
      )
      return .data(ChatInterface.serialize(state))
    }

    registry.register(.chatMute) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let values = try request.values()
      let state = try await interfaces.chat.setMute(
        guid: guid,
        until: try Self.muteExpiry(values.raw),
        // Defaults to true — what Messages' own toggle does.
        syncToPairedDevice: values["syncToPairedDevice"]?.boolValue ?? true
      )
      return .data(ChatInterface.serialize(state))
    }

    registry.register(.chatUnmute) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let state = try await interfaces.chat.unmute(
        guid: try request.requirePathParameter("guid"),
        syncToPairedDevice: values["syncToPairedDevice"]?.boolValue ?? true
      )
      return .data(ChatInterface.serialize(state))
    }

    // MARK: Filtering, spam and history
    //
    // Grouped because they are one piece of state with four ways in: everything except
    // the read funnels through IMCore's `-updateIsFiltered:`.

    registry.register(.chatFilterState) { request in
      let interfaces = try await context.requireInterfaces()
      let state = try await interfaces.chat.filterState(
        guid: try request.requirePathParameter("guid")
      )
      return .data(ChatInterface.serialize(state))
    }

    registry.register(.chatSetFilter) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let category = try values.requireInt("category")
      let state = try await interfaces.chat.setFilter(
        guid: try request.requirePathParameter("guid"), category: category
      )
      return .data(ChatInterface.serialize(state))
    }

    registry.register(.chatMarkKnown) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let state = try await interfaces.chat.markSenderKnown(
        guid: try request.requirePathParameter("guid"),
        // Writing to the address book is opt-in. A client that omits the field is
        // accepting a sender, not editing the user's contacts.
        saveInContacts: values["saveInContacts"]?.boolValue ?? false
      )
      return .data(ChatInterface.serialize(state))
    }

    for (name, isJunk): (HandlerID, Bool) in [(.chatMarkSpam, false), (.chatReportJunk, true)] {
      registry.register(name) { request in
        let interfaces = try await context.requireInterfaces()
        let guid = try request.requirePathParameter("guid")
        let values = try request.values()
        // FALSE by default, and this is the field that most needs it: reporting to a
        // carrier sends an SMS to a shortcode from the user's own number and cannot
        // be withdrawn.
        let toCarrier = values["reportToCarrier"]?.boolValue ?? false
        let dryRun = values["dryRun"]?.boolValue ?? false

        let result =
          isJunk
          ? try await interfaces.chat.reportJunk(
            guid: guid, reportToCarrier: toCarrier, dryRun: dryRun
          )
          : try await interfaces.chat.markSpam(
            guid: guid, reportToCarrier: toCarrier, dryRun: dryRun
          )

        if !dryRun {
          // A remote client just reclassified a conversation on every device on
          // this account. Logging that is not enough — the person at the Mac is
          // the one who has to undo it if it was not them.
          await context.alerts.raise(
            UserAlert(
              severity: .warning,
              title: isJunk ? "A chat was reported as junk" : "A chat was marked as spam",
              body: "\(guid) — \(result.messageCount) message(s)"
                + (toCarrier ? ", reported to the carrier" : "")
                + ". This came from an API client.",
              source: "Chat"
            )
          )
        }
        return .data(ChatInterface.serialize(result))
      }
    }

    /// Empties a conversation. The conversation itself stays — `chat.delete` is the one
    /// that removes it.
    registry.register(.chatClearHistory) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let values = try request.values()

      // An explicit confirmation, because this is not recoverable and the URL alone is
      // one typo away from a conversation nobody meant to empty. Deliberately NOT a
      // query parameter: those get copied between requests.
      guard values["confirm"]?.boolValue == true else {
        throw BadRequest(
          "clearing a chat's history is not reversible — send `{\"confirm\": true}`"
        )
      }

      let deleted = try await interfaces.chat.clearHistory(guid: guid)
      await context.alerts.raise(
        UserAlert(
          severity: .warning,
          title: "A chat's history was cleared",
          body: "\(guid) was emptied by an API client. The messages are gone from "
            + "every device on this account.",
          source: "Chat"
        )
      )
      return .data(.object(["deleted": .bool(deleted)]))
    }

    registry.register(.chatMarkRead) { request in
      let interfaces = try await context.requireInterfaces()
      try await interfaces.chat.markRead(guid: try request.requirePathParameter("guid"))
      return .data(nil)
    }

    registry.register(.chatMarkUnread) { request in
      let interfaces = try await context.requireInterfaces()
      try await interfaces.chat.markUnread(guid: try request.requirePathParameter("guid"))
      return .data(nil)
    }

    registry.register(.chatStartTyping) { request in
      let interfaces = try await context.requireInterfaces()
      try await interfaces.chat.setTyping(
        guid: try request.requirePathParameter("guid"), typing: true
      )
      return .data(nil)
    }

    registry.register(.chatStopTyping) { request in
      let interfaces = try await context.requireInterfaces()
      try await interfaces.chat.setTyping(
        guid: try request.requirePathParameter("guid"), typing: false
      )
      return .data(nil)
    }

    registry.register(.chatAddParticipant) { request in
      try await participant(request, context: context, adding: true)
    }
    registry.register(.chatRemoveParticipant) { request in
      try await participant(request, context: context, adding: false)
    }

    registry.register(.chatUpdate) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let values = try request.values()
      let name = try values.requireString("displayName")
      try await interfaces.chat.setDisplayName(guid: guid, to: name)
      return .data(nil)
    }

    registry.register(.chatSetGroupIcon) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      // Clients send the image as a multipart `icon` part, the way the Node server
      // takes it. A JSON `filePath` is accepted too, for a file already on this Mac.
      let path: String
      if let contentType = request.header("content-type"),
        contentType.hasPrefix("multipart/"), let body = request.body, !body.isEmpty
      {
        let form = try MultipartForm.parse(body: body, contentType: contentType)
        guard let file = form["icon"] ?? form.parts.first(where: { $0.filename != nil })
        else {
          throw BadRequest("no `icon` part in the form")
        }
        path = try UploadStore.write(file.data, named: file.filename ?? "icon")
      } else {
        let values = try request.values()
        guard let given = values["filePath"]?.stringValue ?? values["path"]?.stringValue
        else {
          throw BadRequest("an `icon` file part or a `filePath` is required")
        }
        path = given
      }
      try await interfaces.chat.setGroupPhoto(guid: guid, imagePath: path)
      return .data(nil)
    }

    registry.register(.chatDeleteMessage) { request in
      let interfaces = try await context.requireInterfaces()
      try await interfaces.chat.deleteMessage(
        try request.requirePathParameter("messageGuid"),
        in: try request.requirePathParameter("guid")
      )
      return .data(nil)
    }
  }

  /// Both participant routes, which differ only in direction.
  ///
  /// Four route entries share these two handlers: `POST/DELETE :guid/participant` is the
  /// older form and `POST :guid/participant/{add,remove}` the newer. Both ship, so the
  /// address arrives in a body on one and either place on the other.
  private static func participant(
    _ request: APIRequestContext,
    context: some AlertProviding & InterfaceProviding,
    adding: Bool
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let guid = try request.requirePathParameter("guid")
    let values = try request.values()
    guard
      let address = values["address"]?.stringValue
        ?? request.queryParameters["address"]
    else {
      throw BadRequest("`address` is required")
    }
    if adding {
      try await interfaces.chat.addParticipant(address, to: guid)
    } else {
      try await interfaces.chat.removeParticipant(address, from: guid)
    }
    return .data(nil)
  }
}
