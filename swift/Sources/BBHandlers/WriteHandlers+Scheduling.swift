//  WriteHandlers+Scheduling
//  Send Later: queueing a message, and changing or releasing one before it goes out.
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
  static func registerScheduling(
    into registry: inout HandlerRegistry,
    context: some InterfaceProviding
  ) {
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
  }
}
