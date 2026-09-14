//  WriteHandlers+Chats
//  Conversation administration: creating, leaving, naming, membership, pins, the group
//  photo, read state and typing.
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
  static func registerChatAdministration(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & UploadStoring
  ) {
    registry.register(.chatCreate) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let addresses = values["addresses"]?.arrayValue?.compactMap(\.stringValue) ?? []
      let created = try await interfaces.chat.create(
        addresses: addresses,
        service: values["service"]?.stringValue ?? "iMessage",
        message: values["message"]?.stringValue
      )
      // The WHOLE chat, with its participants and the message the create sent. This
      // answered `{"guid": …}`, which is twelve keys short of what the reference sends and
      // is the break the root guide's rule 1 names: a client reading `data.participants`,
      // `data.displayName` or `data.messages[0].tempGuid` got nothing.
      return .data(
        interfaces.chat.serialize(created, tempGUID: values["tempGuid"]?.stringValue))
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
      // No `total`: the list IS the total, and there is no paging on a handful of
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

    registry.register(.chatUpdate) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let values = try request.values()

      // Participants loaded, because they are part of the response: the reference
      // serializes with `DEFAULT_CHAT_CONFIG` and loads the chat `withParticipants: true`.
      let query = ChatInterface.Query(withParticipants: true)

      // READ FIRST, so a rename against a chat that does not exist is a 404 naming the
      // chat rather than whatever Messages says about a GUID it has never seen.
      // `chatRouter.update` does the same, in the same order.
      guard let before = try await interfaces.chat.find(guid: guid, query: query) else {
        throw NotFound(ReferenceMessages.chatNotFound)
      }

      // NOT `requireString`. The reference's rule is `displayName: "string|min:1"`
      // (`validators/chatValidator.ts:34-36`) — present-and-non-empty IF SENT, and not
      // required — and its controller answers a body with no `displayName` with a 200 and
      // "Chat not updated!". `requireString` made that a 400, which is the one direction
      // that breaks a client: stricter than the reference on a route it already uses.
      var updated: [String] = []
      if let name = values["displayName"]?.stringValue, !name.isEmpty {
        // **MEASURED before this was added** (macOS 26.5.2, 13 September 2026): renaming a
        // one-to-one chat through the helper answered 200 "Successfully updated the
        // following fields: displayName", and then did NOTHING — `chat.display_name`
        // unchanged in chat.db, no group-action row written, nothing sent to the other
        // party, and a read-back reporting the empty name it had before.
        //
        // That measurement is what decides this. Refusing is the stricter direction and
        // normally the one that can break a client, but there is no capability here to take
        // away: the 200 was a false success over a no-op. The reference refuses the same
        // request (`chatRouter.ts:166-168`) and this is its sentence.
        guard before.participants.count > 1 else {
          // The reference's two halves, each in the field it uses: `message` is the
          // envelope's, `error` is `error.message`.
          throw IMessageError(
            "Chat is not a group", message: "Cannot rename a non-group chat!")
        }
        try await interfaces.chat.setDisplayName(guid: guid, to: name)
        updated.append("displayName")
      }

      // Re-read, so the body carries the name that is now set rather than the one it had.
      guard let after = try await interfaces.chat.find(guid: guid, query: query) else {
        throw NotFound(ReferenceMessages.chatNotFound)
      }

      // The chat, not `null`. Both halves were wrong here: the body was empty where the
      // reference sends eleven keys plus `participants`, and the envelope message was the
      // default "Success" where the reference names the fields it applied. The message is
      // built here rather than in `SuccessMessages` because it depends on what happened,
      // which is what that table's header reserves a handler-supplied `message:` for.
      return .data(
        interfaces.chat.serialize(after),
        message: updated.isEmpty
          ? "Chat not updated! No update information provided!"
          : "Successfully updated the following fields: \(updated.joined(separator: ", "))"
      )
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

    registry.register(.chatAddParticipant) { request in
      try await participant(request, context: context, adding: true)
    }

    registry.register(.chatRemoveParticipant) { request in
      try await participant(request, context: context, adding: false)
    }

    registry.register(.chatDeleteMessage) { request in
      let interfaces = try await context.requireInterfaces()
      try await interfaces.chat.deleteMessage(
        try request.requirePathParameter("messageGuid"),
        in: try request.requirePathParameter("guid")
      )
      return .data(nil)
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
  }

  /// Both participant routes, which differ only in direction.
  ///
  /// Four route entries share these two handlers: `POST/DELETE :guid/participant` is the
  /// older form and `POST :guid/participant/{add,remove}` the newer. Both ship, so the
  /// address arrives in a body on one and either place on the other.
  static func participant(
    _ request: APIRequestContext,
    context: some InterfaceProviding,
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
