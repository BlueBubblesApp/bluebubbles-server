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
    into registry: inout HandlerRegistry,
    context: some AlertProviding & InterfaceProviding & UploadStoring
  ) {
    registerSending(into: &registry, context: context)
    registerMultipart(into: &registry, context: context)
    registerMessageActions(into: &registry, context: context)
    registerChatActions(into: &registry, context: context)
  }

  // MARK: - Sending

  private static func registerSending(
    into registry: inout HandlerRegistry,
    context: some AlertProviding & InterfaceProviding & UploadStoring
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
          // The reference's `textFormatting` — styles by range — with `effect` added.
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
      // The client's form — an `attachment` part and string fields — or a JSON `filePath`
      // for a file `attachment/upload` already staged. See `UploadedFileBody`.
      let body = try UploadedFileBody.parse(
        request, filePart: "attachment", uploads: context.uploads
      )
      let values = body.values
      let chatGUID = try values.requireString("chatGuid")
      // The reference validator forces `method` to private-api when any of these is
      // present, and `sendAttachment` does the same by needing the helper for them.
      let sent = try await interfaces.message.sendAttachment(
        chatGUID: chatGUID,
        filePath: body.path,
        isAudioMessage: values.bool("isAudioMessage") ?? false,
        subject: values.string("subject"),
        effectID: values.string("effectId"),
        replyToGUID: values.string("selectedMessageGuid"),
        partIndex: values.int("partIndex")
      )
      // No `tempGuid`, and no error check. The reference injects the temp GUID only on
      // text and multipart — the attachment route reads it from the body for its send cache
      // and does not echo it — and it answers 200 even for a row whose `error` is set.
      return try Self.sendResult(sent, interfaces: interfaces)
    }
  }

  /// `fields` as either an ordered list of `{name, value}` or a plain object.
  ///
  /// The list is the honest form — a query string may repeat a name and some apps care
  /// about order — but an object is what most callers will reach for, so it is accepted and
  /// sorted by name to at least be deterministic.
  private static func appPayloadFields(
    _ value: JSONValue?
  ) throws -> [(name: String, value: String)]? {
    if let array = value?.arrayValue {
      return try array.map { entry in
        guard let name = entry["name"]?.stringValue else {
          throw BadRequest("every entry in `fields` needs a `name`")
        }
        return (name: name, value: entry["value"]?.stringValue ?? "")
      }
    }
    if case .object(let map)? = value {
      return map.map { (name: $0.key, value: $0.value.stringValue ?? "") }
        .sorted { $0.name < $1.name }
    }
    return nil
  }

  /// The response every send route gives: the message it wrote.
  ///
  /// **A send answers with the MESSAGE.** All of them used to answer
  /// `{guid, chatGuid, backend}` — identifiers — where the reference answers the serialised
  /// row, so a client reading back the text, date, handle or chats of what it had just sent
  /// got none of them and had to ask again. The hydration is in `MessageInterface`.
  ///
  /// - Parameter checkingSendError: whether a non-zero `error` on the row becomes a 500.
  ///   **Only `text` and `multipart` do this.** It reads like something that should be
  ///   uniform and is not: `attachment` and `attachment/chunk` return 200 with the failed
  ///   message in `data` and let the client read `error` itself. Both are transcribed rather
  ///   than tidied — a client that has been shown a 200 for a failed attachment since the
  ///   Electron server would start seeing 500s.
  private static func sendResult(
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
          mention: part["mention"]?.stringValue,
          formatting: try TextFormattingBody.parse(part["textFormatting"])
        )
      }

      let sent = try await interfaces.message.sendMultipart(
        chatGUID: chatGUID,
        parts: parts,
        subject: values["subject"]?.stringValue,
        effectID: values["effectId"]?.stringValue,
        replyToGUID: values["selectedMessageGuid"]?.stringValue,
        partIndex: values["partIndex"]?.intValue
      )
      return try Self.sendResult(
        sent, interfaces: interfaces,
        tempGUID: values["tempGuid"]?.stringValue,
        checkingSendError: true
      )
    }
  }

  // MARK: - Message actions

  private static func registerMessageActions(
    into registry: inout HandlerRegistry,
    context: some AlertProviding & InterfaceProviding & UploadStoring
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
      let sent = try await interfaces.message.react(
        chatGUID: chatGUID,
        targetGUID: target,
        reaction: reaction,
        partIndex: values["partIndex"]?.intValue ?? 0,
        // `reaction: "emoji"` (or `"-emoji"`) plus the emoji itself. Additive: the
        // reference's route knows only the six named tapbacks.
        emoji: values["emoji"]?.stringValue
      )
      // The tapback's OWN message, not the one it reacts to. No error check: the
      // reference's reaction route answers 200 whatever the row's `error` says.
      return try Self.sendResult(sent, interfaces: interfaces)
    }

    registry.register(.messageSendLater) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let chatGUID = try values.requireString("chatGuid")
      let message = try values.requireString("message")
      // Epoch MILLISECONDS, the unit every other date on this API uses.
      guard let milliseconds = values.double("scheduledFor") else {
        throw BadRequest("`scheduledFor` is required, as epoch milliseconds")
      }
      let sent = try await interfaces.message.sendText(
        MessageInterface.SendTextRequest(
          chatGUID: chatGUID,
          text: message,
          subject: values.string("subject"),
          effectID: values.string("effectId"),
          replyToGUID: values.string("selectedMessageGuid"),
          partIndex: values.int("partIndex") ?? 0,
          scanForLinks: values.bool("scanForLinks") ?? false,
          formatting: try TextFormattingBody.parse(values["textFormatting"]),
          scheduledFor: Date(timeIntervalSince1970: milliseconds / 1000),
          // Apple's scheduling is a Private API capability; AppleScript cannot express it,
          // and the interface refuses rather than sending now.
          forcedBackend: .privateAPI
        )
      )
      return try Self.sendResult(
        sent, interfaces: interfaces, tempGUID: values.string("tempGuid")
      )
    }

    registry.register(.messagePendingScheduled) { request in
      let interfaces = try await context.requireInterfaces()
      // `chatGuid` scopes to one conversation; without it, every pending message. The
      // `with` relations work as on `message/query`, and `dateCreated` is the delivery time.
      let query = MessageInterface.Query(
        withChats: request.wants("chat"),
        withAttachments: request.wants("attachment"),
        withHandle: true
      )
      let messages = try await interfaces.message.pendingScheduledMessages(
        chatGUID: request.queryParameters["chatGuid"], query: query)
      return .data(
        .array(interfaces.message.serialize(messages, query: query)),
        metadata: .object(["count": .int(messages.count)]))
    }

    // One PUT for both things a pending message can have changed: its text, its delivery
    // time, or both in a single call. Either field alone is a complete request.
    registry.register(.messageReschedule) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let chatGUID = try values.requireString("chatGuid")
      let guid = try request.requirePathParameter("guid")
      let newText = values.string("message", or: "editedMessage")
      let milliseconds = values.double("scheduledFor")
      guard newText != nil || milliseconds != nil else {
        throw BadRequest("`message` or `scheduledFor` is required")
      }
      // Text first: it is the one that can be refused, and a rejected edit should not
      // leave the message already moved.
      if let newText {
        try await interfaces.message.editScheduledMessage(
          chatGUID: chatGUID, messageGUID: guid,
          partIndex: values.int("partIndex") ?? 0, newText: newText)
      }
      if let milliseconds {
        try await interfaces.message.rescheduleMessage(
          chatGUID: chatGUID, messageGUID: guid,
          to: Date(timeIntervalSince1970: milliseconds / 1000))
      }
      return .data(nil)
    }

    registry.register(.messageSendScheduledNow) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      try await interfaces.message.sendScheduledMessageNow(
        chatGUID: try values.requireString("chatGuid"),
        messageGUID: try request.requirePathParameter("guid")
      )
      return .data(nil)
    }

    registry.register(.messageCancelScheduled) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let values = try request.values()
      try await interfaces.message.cancelScheduledMessage(
        chatGUID: try values.requireString("chatGuid"), messageGUID: guid
      )
      // No body: there is no row to answer with once it is cancelled.
      return .data(nil)
    }

    registry.register(.messageAppPayload) { request in
      let interfaces = try await context.requireInterfaces()
      let message = try await interfaces.message.appMessage(
        guid: try request.requirePathParameter("guid"))
      return .data(interfaces.message.serialize(message))
    }

    registry.register(.messageSendApp) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      // Exactly one payload shape. `url` is the escape hatch for an app whose format is
      // neither of the two the server can build; `json` and `fields` save a client from
      // base64ing or percent-encoding anything itself.
      let payload: MessageInterface.AppPayload
      if let url = values.string("url") {
        payload = .url(url)
      } else if let json = values["json"] {
        payload = .json(json)
      } else if let fields = try Self.appPayloadFields(values["fields"]) {
        payload = .fields(fields)
      } else {
        throw BadRequest("one of `url`, `json` or `fields` is required")
      }
      let sent = try await interfaces.message.sendAppMessage(
        chatGUID: try values.requireString("chatGuid"),
        balloonBundleID: try values.requireString("balloonBundleId"),
        payload: payload,
        sessionID: values.string("sessionId"),
        appName: values.string("appName"),
        appID: values.int("appId"),
        summary: values.string("summary"),
        caption: values.string("caption")
      )
      return try Self.sendResult(sent, interfaces: interfaces)
    }

    registry.register(.messageSendGamePigeon) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      // `fields` is an ORDERED list of {name, value}; a plain object is accepted too, for
      // the games that do not care about order.
      guard let fields = try Self.appPayloadFields(values["fields"]) else {
        throw BadRequest("`fields` is required, as a list of {name, value} or an object")
      }
      let sent = try await interfaces.message.sendGamePigeon(
        chatGUID: try values.requireString("chatGuid"),
        version: values.int("version") ?? 52,
        fields: fields,
        sessionID: values.string("sessionId"),
        caption: values.string("caption"),
        teamID: values.string("teamId") ?? "EWFNLB79LQ"
      )
      return try Self.sendResult(sent, interfaces: interfaces)
    }

    registry.register(.messageCreatePoll) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let options = (values.array("options") ?? []).compactMap(\.stringValue)
      let sent = try await interfaces.message.createPoll(
        chatGUID: try values.requireString("chatGuid"),
        title: values.string("title") ?? "",
        options: options
      )
      return try Self.sendResult(sent, interfaces: interfaces)
    }

    registry.register(.messagePoll) { request in
      let interfaces = try await context.requireInterfaces()
      let poll = try await interfaces.message.poll(guid: try request.requirePathParameter("guid"))
      return .data(interfaces.message.serialize(poll))
    }

    registry.register(.messageAddPollOption) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let sent = try await interfaces.message.addPollOption(
        chatGUID: try values.requireString("chatGuid"),
        pollGUID: try request.requirePathParameter("guid"),
        text: try values.requireString("text")
      )
      return try Self.sendResult(sent, interfaces: interfaces)
    }

    registry.register(.messageVotePoll) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      // The voter's COMPLETE selection; an empty array retracts every vote.
      let optionIDs = (values.array("optionIds") ?? []).compactMap(\.stringValue)
      let sent = try await interfaces.message.votePoll(
        chatGUID: try values.requireString("chatGuid"),
        pollGUID: try request.requirePathParameter("guid"),
        optionIDs: optionIDs
      )
      return try Self.sendResult(sent, interfaces: interfaces)
    }

    registry.register(.messageSendSticker) { request in
      let interfaces = try await context.requireInterfaces()
      // The same form the attachment route takes — the sticker image under `attachment`,
      // everything else as string fields — or a JSON `filePath` for a staged file.
      let body = try UploadedFileBody.parse(
        request, filePart: "attachment", uploads: context.uploads
      )
      let values = body.values
      let chatGUID = try values.requireString("chatGuid")
      let target = try values.requireString("selectedMessageGuid")

      // Placement is optional and partial: a client that knows where the user dropped
      // the sticker sends every field; one that only wants "a sticker on this message"
      // sends none and gets the centred default.
      var placement = StickerPlacement.centered
      if let x = values.double("xScalar") { placement.xScalar = x }
      if let y = values.double("yScalar") { placement.yScalar = y }
      if let scale = values.double("scale") { placement.scale = scale }
      if let rotation = values.double("rotation") { placement.rotation = rotation }
      if let width = values.double("parentPreviewWidth") { placement.parentPreviewWidth = width }

      let sent = try await interfaces.message.sendSticker(
        chatGUID: chatGUID,
        filePath: body.path,
        targetGUID: target,
        partIndex: values.int("partIndex") ?? 0,
        placement: placement,
        // `tapback: true` sends it as a tapback (type 2007) instead of a placed sticker,
        // which snaps it to the tapback spot and replaces this account's previous one.
        // `remove: true` takes that back (3007).
        asTapback: values.bool("tapback") ?? false,
        isRemoval: values.bool("remove") ?? false
      )
      // The sticker's OWN message, as `react` answers with the tapback's. No error check,
      // matching the attachment route it takes its file from.
      return try Self.sendResult(sent, interfaces: interfaces)
    }

    registry.register(.messageEdit) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let values = try request.values()
      let text = try values.requireString("editedMessage")
      let edited = try await interfaces.message.edit(
        guid: guid,
        partIndex: values["partIndex"]?.intValue ?? 0,
        newText: text,
        // What a recipient on an older OS sees, since they cannot render an edit.
        // Defaulted rather than required: clients that omit it still work, and the
        // fallback text is what the current server uses.
        backwardCompatibilityText: values["backwardsCompatMessage"]?.stringValue
          ?? "Edited to \u{201C}\(text)\u{201D}"
      )
      return try Self.sendResult(edited, interfaces: interfaces)
    }

    registry.register(.messageUnsend) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let values = try request.values()
      let unsent = try await interfaces.message.unsend(
        guid: guid, partIndex: values["partIndex"]?.intValue ?? 0
      )
      return try Self.sendResult(unsent, interfaces: interfaces)
    }

    registry.register(.messageNotify) { request in
      let interfaces = try await context.requireInterfaces()
      let notified = try await interfaces.message.notify(
        guid: try request.requirePathParameter("guid")
      )
      return try Self.sendResult(notified, interfaces: interfaces)
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
    into registry: inout HandlerRegistry,
    context: some AlertProviding & InterfaceProviding & UploadStoring
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
        path = try context.uploads.write(file.data, named: file.filename ?? "icon")
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
      throw BadRequest("The address field is required.")
    }
    if adding {
      try await interfaces.chat.addParticipant(address, to: guid)
    } else {
      try await interfaces.chat.removeParticipant(address, from: guid)
    }
    return .data(nil)
  }
}
