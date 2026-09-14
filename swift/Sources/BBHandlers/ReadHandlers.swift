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
    registry.register(.messageQuery) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      // Throws on a `where` this server cannot apply; see `MessageFilter`. A 400 naming
      // the statement, rather than a 200 over a filter nobody ran.
      let query: MessageInterface.Query
      do {
        query = try MessageInterface.Query.parse(values.raw)
      } catch let unsupported as MessageFilter.Unsupported {
        throw BadRequest(
          unsupported.statement.isEmpty
            ? "Every entry in `where` needs a `statement`."
            : "This server cannot apply the filter \"\(unsupported.statement)\".")
      }
      let messages = try await interfaces.message.query(query)
      return .data(
        .array(interfaces.message.serialize(messages, query: query)),
        metadata: .object([
          "offset": .int(query.offset),
          "limit": .int(query.limit),
          // EVERY condition the listing was filtered by, `where` included. `requiresChat`
          // and the filters both mirror the listing's own predicate, so the total can
          // never disagree with the pages it is counting: it did, and a client dividing a
          // whole-database total by its page size asked for four hundred pages of a
          // fifty-message delta.
          "total": .int(
            try await interfaces.message.count(
              chatGUID: query.chatGUID, after: query.after, before: query.before,
              requiresChat: query.withChats, filters: query.filters
            )),
          // `count` is how many rows came back on THIS page, as distinct from
          // `total`. A client uses it to decide whether to ask for another page.
          "count": .int(messages.count),
        ])
      )
    }

    registry.register(.messageFind) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      // EVERY relation the reference's `find` reads, not three of them.
      //
      // This declared `withChats`, `withAttachments` and `withHandle` and defaulted the
      // rest, so `?with=attributedBody,messageSummaryInfo,payloadData,chat.participants`
      // was accepted and four of those six silently answered null. On Ventura and newer
      // that includes the message's own words: `text` is null for an outgoing message and
      // `attributedBody` is where they live, so a client fetching one message by GUID got a
      // message with no text and nothing saying why. Compare `messageRouter.find`, which
      // parses the same six.
      let query = MessageInterface.Query(
        withChats: request.wants("chat"),
        withAttachments: request.wants("attachment"),
        withHandle: true,
        withChatParticipants: request.wants("participant"),
        withAttributedBody: request.wants("attributedbody") || request.wants("attributed-body"),
        withMessageSummaryInfo: request.wants("messagesummaryinfo")
          || request.wants("message-summary-info"),
        withPayloadData: request.wants("payloaddata") || request.wants("payload-data")
      )
      guard let message = try await interfaces.message.find(guid: guid, query: query) else {
        throw NotFound(ReferenceMessages.messageNotFound)
      }
      return .data(interfaces.message.serialize(message, query: query))
    }

    // THE SAME FIVE PARAMETERS ON ALL THREE COUNTS, because the reference accepts the same
    // five on all three (`messageRouter.count`, `.sentCount` and `.countUpdated` destructure
    // one identical list). Two of them were read on one route and silently dropped on the
    // others, so "how many have I sent IN THIS CHAT" answered for every chat.
    for (id, options): (HandlerID, (fromMe: Bool, updated: Bool)) in [
      (.messageCount, (false, false)),
      (.messageSentCount, (true, false)),
      (.messageCountUpdated, (false, true)),
    ] {
      registry.register(id) { request in
        let interfaces = try await context.requireInterfaces()
        // `after` is REQUIRED on `count/updated` and optional on the other two, which is
        // the reference's rule and not ours: `messageValidator` declares
        // `after: "required|numeric|min:0"` for that route alone. Recorded as a 400 in
        // `get_api_v1_message_count_updated-5baa61-400.json`, which is what caught an
        // attempt to "fix" this into accepting an absent `after`.
        if options.updated, request.date("after") == nil {
          throw BadRequest("The after field is required.")
        }
        let total = try await interfaces.message.count(
          chatGUID: request.queryParameters["chatGuid"],
          after: request.date("after"),
          before: request.date("before"),
          onlyFromMe: options.fromMe,
          // Inclusive, as the reference's are.
          minRowID: request.integer("minRowId").map(Int64.init),
          maxRowID: request.integer("maxRowId").map(Int64.init),
          updated: options.updated
        )
        return .data(.object(["total": .int(total)]))
      }
    }
  }

  // MARK: - Chat

  private static func registerChat(
    into registry: inout HandlerRegistry,
    context: some AttachmentConverting & InterfaceProviding
  ) {
    registry.register(.chatQuery) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      let query = ChatInterface.Query.parse(values.raw)
      let chats = try await interfaces.chat.query(query)
      // The total has to count the same set the rows came from. Unfiltered that is the
      // whole table; filtered to one GUID it is what the filter matched, and reporting the
      // table's size there would tell a client asking for one chat that there are nine
      // hundred more pages of it.
      let total =
        query.guid == nil
        ? try await interfaces.chat.count(includeArchived: query.includeArchived)
        : chats.count
      return .data(
        .array(interfaces.chat.serialize(chats)),
        metadata: .object([
          "offset": .int(query.offset),
          "limit": .int(query.limit),
          "total": .int(total),
          "count": .int(chats.count),
        ])
      )
    }

    registry.register(.chatFind) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      // Participants only when ASKED for, which is the opposite of `chat/query`'s
      // default and is the reference's behaviour on both: `chatRouter.find` reads
      // `withQuery.includes("participants")` with no fallback, while `chatRouter.query`
      // never consults `with` for participants and takes `getChats`'s default of true.
      // Measured: this route returned `participants: []` there and a populated array
      // here.
      let query = ChatInterface.Query(
        withParticipants: request.wants("participant"),
        withLastMessage: request.wants("lastmessage")
      )
      guard let chat = try await interfaces.chat.find(guid: guid, query: query) else {
        throw NotFound(ReferenceMessages.chatNotFound)
      }
      return .data(interfaces.chat.serialize(chat))
    }

    registry.register(.chatCount) { request in
      let interfaces = try await context.requireInterfaces()
      // Absent means true, matching `withArchived`'s default. `truthy` alone would
      // read an absent parameter as false and silently exclude archived chats.
      let includeArchived =
        request.has("includeArchived") ? request.truthy("includeArchived") : true
      return .data(
        ChatInterface.serialize(
          try await interfaces.chat.countByService(includeArchived: includeArchived)))
    }

    registry.register(.chatMessages) { request in
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
        // this route builds a conversation view from it, and the reference sends it;
        // measured, `data[0].chats` has one entry there and had none here.
        withChats: !request.has("with") || request.wants("chat"),
        withAttachments: !request.has("with") || request.wants("attachment"),
        withHandle: true,
        // THE THREE BLOB COLUMNS, which this route parsed from `with` and this one did not.
        //
        // The reference spells them with a `message.` prefix here and without one on
        // `/message/query` (`chatRouter.getMessages` reads `message.attributedbody`,
        // `messageRouter.query` reads `attributedbody`), which is why `wants` is given both:
        // it matches on a contained substring, so the prefixed spelling a client sends
        // satisfies the bare name too.
        //
        // The app's FULL SYNC pulls every conversation through this route asking for all
        // three (`full_sync_manager.dart`: `attachments,handle,message.attributedBody,
        // message.messageSummaryInfo,message.payloadData`). Dropping them meant a full sync
        // imported no edits, no unsends, no rich-link payloads, and no attributed body —
        // so no mentions, no styling and no part splits. The text survived only because
        // `universalText()` decodes the body server-side to fill `text`.
        withAttributedBody: request.wants("attributedbody") || request.wants("attributed-body"),
        withMessageSummaryInfo: request.wants("messagesummaryinfo")
          || request.wants("message-summary-info"),
        withPayloadData: request.wants("payloaddata") || request.wants("payload-data")
      )
      query.chatGUID = guid
      let messages = try await interfaces.chat.messages(chatGUID: guid, query: query)
      // A client paging through a conversation needs the total to page against.
      return .data(
        .array(interfaces.message.serialize(messages, query: query)),
        metadata: .object([
          // The CLAMPED values, which is what the client was actually given.
          // `MessageInterface.Query` holds the limit to 1...1000 (SQLite reads a negative
          // LIMIT as no limit at all), and echoing the raw request back told a client asking
          // for 5000 that it had 5000, so its next page started 5000 further on and skipped
          // the 4000 it never received. The two sibling routes echo the clamped values and
          // the shared paging helper's own comment states the rule.
          "offset": .int(query.offset),
          "limit": .int(query.limit),
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
    registry.register(.handleQuery) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      // Folded into the range the interface will run with, so the metadata reports the page
      // that was served rather than the one that was asked for.
      let (limit, offset) = HandleInterface.clampedPage(
        limit: values["limit"]?.intValue ?? 1000,
        offset: values["offset"]?.intValue ?? 0
      )
      // `address` and `with` are read from the BODY, which is where the reference reads
      // them and where the Flutter client sends them (`handle_api.dart` posts
      // `{with, address, offset, limit}`). Both were dropped: an app asking for one
      // correspondent's handle and its chats received an unfiltered page of a thousand
      // handles with no chats on any of them.
      let address = values.string("address")
      let relations = (values["with"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        .map { $0.lowercased() }
      let withChats = relations.contains { $0.contains("chat") }
      let handles = try await interfaces.handle.query(
        limit: limit, offset: offset, address: address, withChats: withChats)
      return .data(
        .array(handles.map(interfaces.handle.serialize)),
        metadata: .object([
          "offset": .int(offset),
          "limit": .int(limit),
          // Counted under the SAME filter as the page, for the reason `/message/query`'s
          // total is: a client pages against this number.
          "total": .int(try await interfaces.handle.count(address: address)),
          "count": .int(handles.count),
        ])
      )
    }

    registry.register(.handleCount) { _ in
      let interfaces = try await context.requireInterfaces()
      return .data(.object(["total": .int(try await interfaces.handle.count())]))
    }

    registry.register(.handleFind) { request in
      let interfaces = try await context.requireInterfaces()
      // The path parameter is named `guid` in the route table, but a handle has no
      // GUID; the value is the address. Kept as-is because the route template is part
      // of the compatibility contract.
      let address = try request.requirePathParameter("guid")
      guard
        let handle = try await interfaces.handle.find(
          address: address, withChats: request.wants("chat")
        )
      else {
        throw NotFound(ReferenceMessages.handleNotFound)
      }
      return .data(interfaces.handle.serialize(handle))
    }

    registry.register(.handleIMessageAvailability) { request in
      let interfaces = try await context.requireInterfaces()
      let address = try request.requireQueryParameter("address")
      let available = try await interfaces.handle.availability(
        address: address, service: .iMessage
      )
      return .data(.object(["available": .bool(available)]))
    }

    registry.register(.handleFaceTimeAvailability) { request in
      let interfaces = try await context.requireInterfaces()
      let address = try request.requireQueryParameter("address")
      let available = try await interfaces.handle.availability(
        address: address, service: .faceTime
      )
      return .data(.object(["available": .bool(available)]))
    }

    registry.register(.handleFocusStatus) { request in
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
    registry.register(.attachmentCount) { _ in
      let interfaces = try await context.requireInterfaces()
      return .data(.object(["total": .int(try await interfaces.attachment.count())]))
    }

    registry.register(.attachmentFind) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      guard let attachment = try await interfaces.attachment.find(guid: guid) else {
        throw NotFound(ReferenceMessages.attachmentNotFound)
      }
      return .data(await interfaces.attachment.serialize(attachment))
    }

    // Streamed from disk rather than buffered: a 500 MB video must not enter the heap.
    //
    // Converted first, unless `original=true`. iMessage stores what the sender's device
    // produced (an iPhone photo is HEIC, a voice note is CAF) and most clients can open
    // neither, so the Node server converts on download and every shipped client relies on
    // it.
    registry.register(.attachmentDownload) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      let path = try await interfaces.attachment.resolvePath(guid: guid)
      let metadata = try await interfaces.attachment.find(guid: guid)

      // Validated the way the reference's `AttachmentValidator.downloadRules` validates:
      // `quality` in good/better/best, `width` and `height` numeric and at least 1. Both
      // rejections are 400s the reference already returns, so a client that sees one here
      // saw one there too. Left un-validated, `?quality=inf` trapped the process.
      let quality = try request.enumeration(
        "quality",
        as: AttachmentConversion.Options.Quality.self,
        rejection: AttachmentConversion.Options.Quality.rejectionMessage
      )
      let width = try request.positiveInteger("width")
      let height = try request.positiveInteger("height")

      let served = await context.attachmentConversion.resolve(
        path: path,
        mimeType: metadata?.mimeType ?? FileTypes.mimeType(for: path),
        options: AttachmentConversion.Options(
          original: request.truthy("original"),
          quality: quality,
          width: width,
          height: height
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

    registry.register(.attachmentBlurhash) { request in
      let interfaces = try await context.requireInterfaces()
      let guid = try request.requirePathParameter("guid")
      // `width`, `height` and `quality` are the reference's parameters here and were all
      // three ignored; `componentX`/`componentY` are ours and the reference's route reads
      // neither, so they stay as an additive extra. The defaults now match the reference's
      // (3, 3) — they did not, and since the component counts are encoded in the hash
      // itself, the identical default request returned a different string.
      //
      // `quality` is accepted and has no effect: it selects Electron's `nativeImage` resize
      // filter, which has no counterpart in the Core Graphics path this uses. Named here
      // rather than silently swallowed, because that is the distinction this whole audit
      // was about; it changes no field a client can read.
      let requestedEdge = [request.integer("width"), request.integer("height")]
        .compactMap { $0 }.filter { $0 > 0 }.max()
      let hash = try await interfaces.attachment.blurhash(
        guid: guid,
        components: (
          request.integer("componentX") ?? 3,
          request.integer("componentY") ?? 3
        ),
        maximumEdge: requestedEdge
      )
      return .data(.string(hash))
    }
  }

  // MARK: - Contact

  private static func registerContact(
    into registry: inout HandlerRegistry,
    context: some AttachmentConverting & InterfaceProviding
  ) {
    // `extraProperties=avatar` is honoured on all three contact reads, which is where the
    // reference reads it (query string on the two GETs, body on `POST /contact/query`).
    // It was accepted and ignored, so a client asking for photos got contacts with an empty
    // `avatar` and had to make one more request per contact to fill them in.
    registry.register(.contactList) { request in
      let interfaces = try await context.requireInterfaces()
      let contacts = try await interfaces.contact.list(
        limit: request.integer("limit") ?? 1000,
        offset: request.integer("offset") ?? 0
      )
      return .data(
        .array(
          await interfaces.contact.serialize(
            page: contacts,
            extraProperties: request.queryParameters["extraProperties"])))
    }

    /// Two shapes on one route: with `addresses`, it resolves them; without, it lists.
    /// That is what the reference does and clients rely on both.
    registry.register(.contactQuery) { request in
      let interfaces = try await context.requireInterfaces()
      let values = try request.values()
      // An `addresses` that is not an array used to read as an empty one, and empty means
      // "list everything", so a client sending a bare string got an unfiltered page instead
      // of the contact it asked about. The reference refuses it in the handler
      // (`contactRouter.ts:22`) with this sentence, which is why the rule table has no entry
      // for the field.
      let addresses = try Self.requestedAddresses(values["addresses"])
      let contacts =
        addresses.isEmpty
        ? try await interfaces.contact.list(
          limit: values["limit"]?.intValue ?? 1000,
          offset: values["offset"]?.intValue ?? 0
        )
        : try await interfaces.contact.find(addresses: addresses)
      // From the BODY here, and it may be a list or a comma-separated string: the reference
      // passes it through `parseWithQuery(body?.extraProperties ?? [], false)`, which takes
      // either.
      let extra =
        values["extraProperties"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ",")
        ?? values.string("extraProperties")
      return .data(
        .array(
          await interfaces.contact.serialize(page: contacts, extraProperties: extra)))
    }

    registry.register(.contactAvatar) { request in
      let interfaces = try await context.requireInterfaces()
      let identifier = try request.requirePathParameter("id")
      let data = try await interfaces.contact.avatar(address: identifier)
      return .bytes(data, contentType: "image/jpeg")
    }
  }

  /// The `addresses` of `POST /api/v1/contact/query`: a list of strings, or nothing.
  ///
  /// Refused rather than coerced. Absent is "list every contact", which is a documented
  /// shape of this route; a STRING where a list belongs is a client bug, and turning it into
  /// "list every contact" answers a question nobody asked with a page of everyone.
  static func requestedAddresses(_ raw: JSONValue?) throws -> [String] {
    guard let raw, !raw.isNull else { return [] }
    guard let elements = raw.arrayValue else {
      throw BadRequest("Addresses must be an array of strings!")
    }
    return try elements.map { element in
      guard let address = element.stringValue else {
        throw BadRequest("Addresses must be an array of strings!")
      }
      return address
    }
  }

}
