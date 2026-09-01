//  ReadHandlers
//  Controllers for everything that reads chat.db and the contact index.
//
//  Thin by design: each one parses its request, calls the interfaces layer, and returns.
//  Anything that looks like a decision belongs one level down, where the SwiftUI app and the
//  socket handlers can reach it too. See `.claude/docs/api.md`.

import BBHTTPAPI
import BBIMessage
import BBInterfaces
import BBSerialization
import BBSystem
import Foundation

public enum ReadHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some AttachmentConverting & InterfaceProviding
  ) {
    registerMessage(into: &registry, context: context)
    registerChat(into: &registry, context: context)
    registerHandle(into: &registry, context: context)
    registerAttachment(into: &registry, context: context)
    registerContact(into: &registry, context: context)
  }

  // MARK: - Message

  private static func registerMessage(
    into registry: inout HandlerRegistry,
    context: some AttachmentConverting & InterfaceProviding
  ) {
    registry.register("message.query") { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let query = MessageInterface.Query.parse(values.raw)
      let messages = try await interfaces.message.query(query)
      return .data(
        .array(interfaces.message.serialize(messages, query: query)),
        metadata: .object([
          "offset": .int(query.offset),
          "limit": .int(query.limit),
          // `requiresChat` mirrors the listing's own predicate, so the total can
          // never disagree with the pages it is counting.
          "total": .int(
            try await interfaces.message.count(
              chatGUID: query.chatGUID, after: query.after, before: query.before,
              requiresChat: query.withChats
            )),
          // `count` is how many rows came back on THIS page, as distinct from
          // `total`. It was missing from every paginated response; a client using
          // it to decide whether to ask for another page saw `undefined`.
          "count": .int(messages.count),
        ])
      )
    }

    registry.register("message.find") { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let query = MessageInterface.Query(
        withChats: request.wants("chat"),
        withAttachments: request.wants("attachment"),
        withHandle: true
      )
      guard let message = try await interfaces.message.find(guid: guid, query: query) else {
        throw NotFound("no message with GUID \(guid)")
      }
      return .data(interfaces.message.serialize(message, query: query))
    }

    registry.register("message.count") { request in
      let interfaces = try await context.requireInterfaces()
      let total = try await interfaces.message.count(
        chatGUID: request.queryParameters["chatGuid"],
        after: request.date("after"),
        before: request.date("before")
      )
      return .data(.object(["total": .int(total)]))
    }

    registry.register("message.sentCount") { request in
      let interfaces = try await context.requireInterfaces()
      let total = try await interfaces.message.count(
        after: request.date("after"),
        before: request.date("before"),
        onlyFromMe: true
      )
      return .data(.object(["total": .int(total)]))
    }

    registry.register("message.countUpdated") { request in
      let interfaces = try await context.requireInterfaces()
      // `after` is required here, unlike on the other counts: without it this asks
      // "how many messages have ever been delivered or read", which is every message
      // and is not what any client wants.
      guard let after = request.date("after") else {
        throw BadRequest("`after` is required")
      }
      let total = try await interfaces.message.updatedCount(
        after: after, before: request.date("before")
      )
      return .data(.object(["total": .int(total)]))
    }
  }

  // MARK: - Chat

  private static func registerChat(
    into registry: inout HandlerRegistry,
    context: some AttachmentConverting & InterfaceProviding
  ) {
    registry.register("chat.query") { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let query = ChatInterface.Query.parse(values.raw)
      let chats = try await interfaces.chat.query(query)
      return .data(
        .array(interfaces.chat.serialize(chats)),
        metadata: .object([
          "offset": .int(query.offset),
          "limit": .int(query.limit),
          "total": .int(
            try await interfaces.chat.count(
              includeArchived: query.includeArchived
            )),
          "count": .int(chats.count),
        ])
      )
    }

    registry.register("chat.find") { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      // Participants only when ASKED for, which is the opposite of `chat/query`'s
      // default and is the reference's behaviour on both: `chatRouter.find` reads
      // `withQuery.includes("participants")` with no fallback, while `chatRouter.query`
      // never consults `with` for participants and takes `getChats`'s default of true.
      // Measured — this route returned `participants: []` there and a populated array
      // here.
      let query = ChatInterface.Query(
        withParticipants: request.wants("participant"),
        withLastMessage: request.wants("lastmessage")
      )
      guard let chat = try await interfaces.chat.find(guid: guid, query: query) else {
        throw NotFound("no chat with GUID \(guid)")
      }
      return .data(interfaces.chat.serialize(chat))
    }

    registry.register("chat.count") { request in
      let interfaces = try await context.requireInterfaces()
      // Absent means true, matching `withArchived`'s default. `truthy` alone would
      // read an absent parameter as false and silently exclude archived chats.
      let includeArchived =
        request.has("includeArchived") ? request.truthy("includeArchived") : true
      return .data(try await interfaces.chat.countByService(includeArchived: includeArchived))
    }

    registry.register("chat.messages") { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let limit = request.integer("limit") ?? 100
      let offset = request.integer("offset") ?? 0
      var query = MessageInterface.Query(
        limit: limit,
        offset: offset,
        ascending: (request.queryParameters["sort"] ?? "DESC").uppercased() == "ASC",
        after: request.date("after"),
        before: request.date("before"),
        // The chat the messages came from is included by default. A client reading
        // this route builds a conversation view from it, and the reference sends it —
        // measured, `data[0].chats` has one entry there and had none here.
        withChats: !request.has("with") || request.wants("chat"),
        withAttachments: !request.has("with") || request.wants("attachment"),
        withHandle: true
      )
      query.chatGUID = guid
      let messages = try await interfaces.chat.messages(chatGUID: guid, query: query)
      // This route returned no metadata at all, so a client paging through a
      // conversation had no total to page against.
      return .data(
        .array(interfaces.message.serialize(messages, query: query)),
        metadata: .object([
          "offset": .int(offset),
          "limit": .int(limit),
          "total": .int(try await interfaces.message.count(chatGUID: guid)),
          "count": .int(messages.count),
        ])
      )
    }
  }

  // MARK: - Handle

  private static func registerHandle(
    into registry: inout HandlerRegistry,
    context: some AttachmentConverting & InterfaceProviding
  ) {
    registry.register("handle.query") { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let limit = values["limit"]?.intValue ?? 1000
      let offset = values["offset"]?.intValue ?? 0
      let handles = try await interfaces.handle.query(limit: limit, offset: offset)
      return .data(
        .array(handles.map(interfaces.handle.serialize)),
        metadata: .object([
          "offset": .int(offset),
          "limit": .int(limit),
          "total": .int(try await interfaces.handle.count()),
          "count": .int(handles.count),
        ])
      )
    }

    registry.register("handle.count") { _ in
      let interfaces = try await context.requireInterfaces()
      return .data(.object(["total": .int(try await interfaces.handle.count())]))
    }

    registry.register("handle.find") { request in
      let interfaces = try await context.requireInterfaces()
      // The path parameter is named `guid` in the route table, but a handle has no
      // GUID — the value is the address. Kept as-is because the route template is part
      // of the compatibility contract.
      let address = try request.requirePathParameter("guid")
      guard
        let handle = try await interfaces.handle.find(
          address: address, withChats: request.wants("chat")
        )
      else {
        throw NotFound("no handle with address \(address)")
      }
      return .data(interfaces.handle.serialize(handle))
    }

    registry.register("handle.iMessageAvailability") { request in
      let interfaces = try await context.requireInterfaces()
      let address = try request.requireQueryParameter("address")
      let available = try await interfaces.handle.availability(
        address: address, service: .iMessage
      )
      return .data(.object(["available": .bool(available)]))
    }

    registry.register("handle.faceTimeAvailability") { request in
      let interfaces = try await context.requireInterfaces()
      let address = try request.requireQueryParameter("address")
      let available = try await interfaces.handle.availability(
        address: address, service: .faceTime
      )
      return .data(.object(["available": .bool(available)]))
    }

    registry.register("handle.focusStatus") { request in
      let interfaces = try await context.requireInterfaces()
      let address = try request.requirePathParameter("guid")
      let status = try await interfaces.handle.focusStatus(address: address)
      return .data(.object(["status": .string(status)]))
    }
  }

  // MARK: - Attachment

  private static func registerAttachment(
    into registry: inout HandlerRegistry,
    context: some AttachmentConverting & InterfaceProviding
  ) {
    registry.register("attachment.count") { _ in
      let interfaces = try await context.requireInterfaces()
      return .data(.object(["total": .int(try await interfaces.attachment.count())]))
    }

    registry.register("attachment.find") { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      guard let attachment = try await interfaces.attachment.find(guid: guid) else {
        throw NotFound("no attachment with GUID \(guid)")
      }
      return .data(interfaces.attachment.serialize(attachment))
    }

    // Streamed from disk rather than buffered — a 500 MB video must not enter the heap.
    //
    // Converted first, unless `original=true`. iMessage stores what the sender's device
    // produced — an iPhone photo is HEIC, a voice note is CAF — and most clients can open
    // neither, so the Node server converts on download and every shipped client relies on
    // it. This handler ignored `original`, `quality`, `width` and `height` entirely and
    // served the raw file, so an Android client asking for a photo got a HEIC.
    registry.register("attachment.download") { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let path = try await interfaces.attachment.resolvePath(guid: guid)
      let metadata = try await interfaces.attachment.find(guid: guid)

      let served = await context.attachmentConversion.resolve(
        path: path,
        mimeType: metadata?.mimeType ?? FileTypes.mimeType(for: path),
        options: AttachmentConversion.Options(
          original: request.truthy("original"),
          quality: request.decimal("quality"),
          width: request.integer("width"),
          height: request.integer("height")
        )
      )

      return .file(
        path: served.path,
        // The ORIGINAL filename, even when a converted file is served: the client
        // shows this to the user and saves under it, and a hashed cache name would
        // be what they saw.
        filename: metadata?.transferName,
        contentType: served.mimeType
      )
    }

    registry.register("attachment.blurhash") { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let hash = try await interfaces.attachment.blurhash(
        guid: guid,
        components: (
          request.integer("componentX") ?? 4,
          request.integer("componentY") ?? 3
        )
      )
      return .data(.string(hash))
    }
  }

  // MARK: - Contact

  private static func registerContact(
    into registry: inout HandlerRegistry,
    context: some AttachmentConverting & InterfaceProviding
  ) {
    registry.register("contact.list") { request in
      let interfaces = try await context.requireInterfaces()
      let contacts = try await interfaces.contact.list(
        limit: request.integer("limit") ?? 1000,
        offset: request.integer("offset") ?? 0
      )
      return .data(.array(contacts))
    }

    /// Two shapes on one route: with `addresses`, it resolves them; without, it lists.
    /// That is what the current server does and clients rely on both.
    registry.register("contact.query") { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let addresses = values["addresses"]?.arrayValue?.compactMap(\.stringValue) ?? []
      let contacts =
        addresses.isEmpty
        ? try await interfaces.contact.list(
          limit: values["limit"]?.intValue ?? 1000,
          offset: values["offset"]?.intValue ?? 0
        )
        : try await interfaces.contact.find(addresses: addresses)
      return .data(.array(contacts))
    }

    registry.register("contact.avatar") { request in
      let interfaces = try await context.requireInterfaces()
      let identifier = try request.requirePathParameter("id")
      let data = try await interfaces.contact.avatar(address: identifier)
      return .bytes(data, contentType: "image/jpeg")
    }
  }
}

// MARK: - Request reading
//
// Small enough to be obvious, and worth having in one place: every one of these was being
// written slightly differently at each call site, and "did this route accept `chatGuid` or
// `chat_guid`" is exactly the kind of drift the parity harness cannot see.

extension APIRequestContext {

  /// A query parameter as a date. Epoch MILLISECONDS, matching the wire format.
  func date(_ name: String) -> Date? {
    guard let raw = queryParameters[name], let milliseconds = Double(raw) else { return nil }
    return Date(timeIntervalSince1970: milliseconds / 1000)
  }

  func has(_ name: String) -> Bool {
    queryParameters[name] != nil
  }

  func decimal(_ name: String) -> Double? {
    queryParameters[name].flatMap(Double.init)
  }

  /// A boolean query parameter, matching `isTruthyBool` in the current server.
  ///
  /// Clients spell these several ways and have for years — `?original=1`, `?original=true`,
  /// and a bare `?original` with no value. Accepting only `"true"` would silently ignore
  /// two of the three and serve a converted file to a caller who asked for the original.
  func truthy(_ name: String) -> Bool {
    guard let raw = queryParameters[name] else { return false }
    // Present but empty is `?original`, which is an assertion, not an absence.
    if raw.isEmpty { return true }
    return ["1", "true", "yes"].contains(raw.lowercased())
  }

  /// Whether the `with` parameter asks for a relation.
  ///
  /// Substring rather than equality: clients spell the same relation several ways —
  /// `chat`, `chats`, `chat.participants` — and the current server accepts all of them.
  func wants(_ relation: String) -> Bool {
    guard let raw = queryParameters["with"] else { return false }
    return raw.lowercased()
      .split(separator: ",")
      .contains { $0.trimmingCharacters(in: .whitespaces).contains(relation) }
  }
}
