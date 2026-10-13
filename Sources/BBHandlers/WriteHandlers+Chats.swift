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
    registry.register(.chatCreate) { try await chatCreate($0, context: context) }
    registry.register(.chatDelete) { try await chatDelete($0, context: context) }
    registry.register(.chatLeave) { try await chatLeave($0, context: context) }
    registry.register(.chatPinned) { try await chatPinned($0, context: context) }
    // Two handlers over one call, so the pinned flag lives in the route rather than in
    // a body a client can omit.
    for (name, pinned): (HandlerID, Bool) in [(.chatPin, true), (.chatUnpin, false)] {
      registry.register(name) { try await chatSetPinned($0, context: context, pinned: pinned) }
    }
    registry.register(.chatUpdate) { try await chatUpdate($0, context: context) }
    registry.register(.chatSetGroupIcon) { try await chatSetGroupIcon($0, context: context) }
    registry.register(.chatAddParticipant) {
      try await participant($0, context: context, adding: true)
    }
    registry.register(.chatRemoveParticipant) {
      try await participant($0, context: context, adding: false)
    }
    registry.register(.chatDeleteMessage) { try await chatDeleteMessage($0, context: context) }
    registry.register(.chatMarkRead) { try await chatMarkRead($0, context: context) }
    registry.register(.chatMarkUnread) { try await chatMarkUnread($0, context: context) }
    registry.register(.chatStartTyping) { try await chatStartTyping($0, context: context) }
    registry.register(.chatStopTyping) { try await chatStopTyping($0, context: context) }
  }

  private static func chatCreate(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let values = try request.values()
    // `strings`, which refuses an element that is not a string rather than dropping it:
    // `["+12025550143", 12025550144]` used to create the chat without the second person,
    // answered 200. The reference cannot create that chat either (`slugifyAddress` calls
    // a string method on each element and throws), so no working client sends one.
    let addresses = try values.strings("addresses") ?? []
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

  private static func chatDelete(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    try await interfaces.chat.delete(guid: try request.requirePathParameter("guid"))
    return .data(nil)
  }

  private static func chatLeave(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    try await interfaces.chat.leave(guid: try request.requirePathParameter("guid"))
    return .data(nil)
  }

  private static func chatPinned(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let chats = try await interfaces.chat.pinned(
      query: ChatInterface.Query(
        withParticipants: !request.has("with") || request.wants("participant"),
        withLastMessage: request.wants("lastmessage")
      )
    )
    // No window and no `total`: the list IS the total, and there is no paging on a
    // handful of pins. `count` is still reported so the shape matches every other listing.
    return .page(interfaces.chat.serialize(chats))
  }

  private static func chatSetPinned(
    _ request: APIRequestContext,
    context: some InterfaceProviding,
    pinned: Bool
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    try await interfaces.chat.setPinned(
      guid: try request.requirePathParameter("guid"), pinned: pinned
    )
    return .data(nil)
  }

  private static func chatUpdate(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    // NOT `requireString`. The reference's rule is `displayName: "string|min:1"`
    // (`validators/chatValidator.ts:34-36`): present-and-non-empty IF SENT, and not
    // required. Its controller answers a body with no `displayName` with a 200 and "Chat not
    // updated!", and a 400 there would be stricter than the reference on a route clients
    // already use.
    let update = try await interfaces.chat.update(
      guid: try request.requirePathParameter("guid"),
      displayName: try request.values()["displayName"]?.stringValue
    )

    // The chat, with participants: the reference serializes with `DEFAULT_CHAT_CONFIG`. The
    // envelope message names the fields applied, as the reference's does; it is built here
    // because it depends on what happened, which is what `SuccessMessages`' header reserves
    // a handler-supplied `message:` for.
    return .data(
      interfaces.chat.serialize(update.chat),
      message: update.updatedFields.isEmpty
        ? "Chat not updated! No update information provided!"
        : "Successfully updated the following fields: "
          + update.updatedFields.joined(separator: ", ")
    )
  }

  private static func chatSetGroupIcon(
    _ request: APIRequestContext,
    context: some InterfaceProviding & UploadStoring
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    let guid = try request.requirePathParameter("guid")
    // Clients send the image as a multipart `icon` part, the way the Node server takes
    // it. A JSON `filePath` is accepted too, for a file already on this Mac, CONFINED as
    // on the send routes: this path reaches `setGroupPhoto`, which hands it to Messages,
    // so an unconfined value would publish an arbitrary file as a group's photo.
    //
    // No icon, an empty one, or no path is the reference's one 400 for all of them.
    // `nameField: nil` because a group photo has no recipient-facing filename to take.
    let icon = try UploadedFileBody.parse(
      request, filePart: "icon", uploads: context.uploads, nameField: nil,
      missingFile: ReferenceMessages.chatIconNotProvided)
    try await interfaces.chat.setGroupPhoto(guid: guid, imagePath: icon.path)
    return .data(nil)
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
    // The chat, with its participants, as the reference answers (`toggleParticipant`
    // serialises the chat it read `withParticipants: true`). `data: null` was a v1 field
    // missing: a client reading the new roster from the reply found nothing.
    guard
      let chat = try await interfaces.chat.find(
        guid: guid, query: ChatInterface.Query(withParticipants: true))
    else {
      throw NotFound(ReferenceMessages.chatNotFound)
    }
    return .data(interfaces.chat.serialize(chat))
  }

  private static func chatDeleteMessage(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    try await interfaces.chat.deleteMessage(
      try request.requirePathParameter("messageGuid"),
      in: try request.requirePathParameter("guid")
    )
    return .data(nil)
  }

  private static func chatMarkRead(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    try await interfaces.chat.markRead(guid: try request.requirePathParameter("guid"))
    return .data(nil)
  }

  private static func chatMarkUnread(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    try await interfaces.chat.markUnread(guid: try request.requirePathParameter("guid"))
    return .data(nil)
  }

  private static func chatStartTyping(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    try await interfaces.chat.setTyping(
      guid: try request.requirePathParameter("guid"), typing: true
    )
    return .data(nil)
  }

  private static func chatStopTyping(
    _ request: APIRequestContext,
    context: some InterfaceProviding
  ) async throws -> RouteResult {
    let interfaces = try await context.requireInterfaces()
    try await interfaces.chat.setTyping(
      guid: try request.requirePathParameter("guid"), typing: false
    )
    return .data(nil)
  }
}
