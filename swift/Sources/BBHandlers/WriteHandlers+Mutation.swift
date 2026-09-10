//  WriteHandlers+Mutation
//  Changing a message that exists: reactions, stickers, edits, unsends, notifications, and
//  the media an app balloon generated.
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
  static func registerMutation(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding & UploadStoring
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

    registry.register(.messageSendSticker) { request in
      let interfaces = try await context.requireInterfaces()
      // The same form the attachment route takes (the sticker image under `attachment`,
      // everything else as string fields) or a JSON `filePath` for a staged file.
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
        // fallback text is what the reference uses.
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
}
