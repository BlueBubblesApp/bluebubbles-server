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
