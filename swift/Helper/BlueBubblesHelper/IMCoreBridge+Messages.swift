//  IMCoreBridge+Messages
//  Changing or asking about a message that already exists: editing, unsending,
//  deleting, searching. `MessageMutation` and `MessageQuerying`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  /// PORTED. ObjC: `editMessageInChat:` (BlueBubblesHelper.m:1142).
  ///
  /// Through ChatKit, taking a COMPOSITION. The previous pass used IMChat's
  /// `editMessageItem:atPartIndex:withNewPartText:…backwardCompatabilityText:`, which is
  /// the pre-refactor path.
  ///
  /// `backwardCompatibilityText` is accepted and unused: the ChatKit selector has no
  /// parameter for it, and Messages derives what older devices see itself. Kept in the
  /// signature because it is part of the wire contract clients already send.
  public func editMessage(
    _ guid: MessageGUID,
    in chat: ChatIdentifier,
    partIndex: Int,
    newText: String,
    backwardCompatibilityText: String
  ) async throws {
    let message = try await IMChatHistory.message(guid: guid.rawValue)
    return try translating {
      let item = (try? IMCoreRuntime.send(message, "_imMessageItem")) ?? message
      let composition = try CKCompositions.withText(newText)
      try requireConversation(chat).editMessage(
        item: item, partIndex: partIndex, composition: composition
      )
    }
  }

  /// PORTED. ObjC: `unsendMessageInChat:` (BlueBubblesHelper.m:1162).
  ///
  /// `retractMessagePart:` on the CONVERSATION, taking the chat item for the part being
  /// unsent. It addresses a PART: a message with text and an attachment has two, and
  /// unsending one leaves the other standing.
  public func unsendMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int
  ) async throws {
    let part = try await IMChatHistory.messagePartChatItem(
      guid: guid.rawValue, partIndex: partIndex
    )
    return try translating {
      try requireConversation(chat).retractMessagePart(part)
    }
  }

  /// PORTED. ObjC: `deleteMessageInChat:` (BlueBubblesHelper.m:1185).
  ///
  /// `deleteChatItem:` on the CHAT CONTROLLER, once per part: not `deleteChatItems:` on
  /// IMChat, which is a different operation on different objects.
  ///
  /// Local only: this removes the message from THIS Mac. It is not an unsend: the
  /// recipient keeps their copy.
  /// PORTED, but not the way the reference does it.
  ///
  /// The reference builds a `CKChatController` and calls `deleteChatItem:` on it. MEASURED
  /// on macOS 26: that selector still responds (it is inherited from
  /// `CKCoreChatController`) and does nothing. `CKChatController` is a `UIViewController`,
  /// and one constructed headlessly has no loaded view and no chat items to remove, so the
  /// call succeeds against an empty collection. The delete reported success and chat.db was
  /// untouched, which is the worst shape a failure can take.
  ///
  /// `IMChat.deleteChatItems:` is the model-layer equivalent and needs no view at all.
  public func deleteMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    let message = try await IMChatHistory.message(guid: guid.rawValue)
    return try translating {
      let imChat = try IMChatRegistry.requireChat(guid: chat.rawValue)
      let item = (try? IMCoreRuntime.send(message, "_imMessageItem")) ?? message
      // MEASURED on macOS 26: `deleteChatItems:` with the items off a freshly loaded
      // message item returns without raising and deletes nothing: three app-message rows
      // stayed in chat.db after three 200s. Those chat items are not the ones the chat's
      // transcript holds, so the chat has nothing to match them against.
      // `deleteIMMessageItems:` takes the MESSAGE ITEM, which is what was loaded, and is
      // the model-layer delete.
      let selector = "deleteIMMessageItems:"
      if IMCoreRuntime.responds(imChat.object, to: NSSelectorFromString(selector)) {
        try IMCoreRuntime.invoke(imChat.object, selector, [[item]])
        return
      }
      guard let items = try? IMCoreRuntime.send(item, "_newChatItems") else {
        throw PrivateAPIErrorShim.rejected("that message exposes no chat items")
      }
      // `_newChatItems` is a single item for a plain message and an array for a
      // multipart one; the delete takes an array either way.
      try IMCoreRuntime.invoke(
        imChat.object, "deleteChatItems:", [(items as? [AnyObject]) ?? [items]]
      )
    }
  }

  /// PORTED. ObjC: `[chat markChatItemAsNotifyRecipient:]` (BlueBubblesHelper.m:630).
  ///
  /// Delivers a notification Focus would have suppressed: "Notify Anyway" in Messages.
  /// It addresses a CHAT ITEM, not the message item: an earlier pass called
  /// `setShouldNotifyOnSend:` on the message, which is a different property about
  /// outgoing sends and does nothing for this.
  public func notifyAnyways(_ guid: MessageGUID, in chatGUID: ChatIdentifier) async throws {
    let item = try await IMChatHistory.messageItem(guid: guid.rawValue)
    return try translating {
      // The chat GUID from the request is what resolves this, not the item; see the
      // contract. `chat(owning:)` is still asked first so a message that DOES name its
      // chat keeps working, and the request's GUID is the fallback that makes it work
      // at all.
      let chat = try Self.chat(owning: item, fallbackGUID: chatGUID.rawValue)
      let container = (try? IMCoreRuntime.send(item, "_imMessageItem")) ?? item
      guard let items = try? IMCoreRuntime.send(container, "_newChatItems") else {
        throw PrivateAPIErrorShim.rejected("that message exposes no chat items")
      }
      // The FIRST part, matching the reference: the notification is for the message,
      // and any of its parts identifies it.
      guard let first = (items as? [AnyObject])?.first ?? items as AnyObject? else {
        throw PrivateAPIErrorShim.rejected("that message has no parts to notify on")
      }
      try IMCoreRuntime.invoke(
        chat.object, "markChatItemAsNotifyRecipient:", [first]
      )
    }
  }

  /// NOT PORTED, and deliberately left that way.
  ///
  /// The Objective-C helper implements search against IMCore's own index. The server does
  /// not need it: it reads chat.db directly, where `MessageRepository` already answers the
  /// same question with SQL: over the full history, with paging, and without a round trip
  /// into Messages. Porting this would add a second, slower implementation of a query that
  /// already works, and a second set of results for clients to disagree about.
  ///
  /// Left as `notImplemented` rather than deleted because it is part of the contract the
  /// shipping helper exposes, and the honest answer is "this helper does not do that".
  public func searchMessages(_ request: MessageSearchRequest) async throws -> [MessageGUID] {
    throw PrivateAPIError.notImplemented(method: "searchMessages")
  }

  /// PORTED. ObjC: `balloon-bundle-media-path` (BlueBubblesHelper.m:523).
  ///
  /// Digital Touch and handwritten messages carry no text and no ordinary attachment. The
  /// content is a plugin data source, and the media does not exist as a file until the
  /// plugin is asked to GENERATE it: there is no file transfer to look for.
  ///
  /// `generateMedia:` calls back when the asset has been written, and only then does
  /// `assetURL` mean anything.
  public func balloonBundleMediaPath(for guid: MessageGUID) async throws -> String {
    let item = try await IMChatHistory.messageItem(guid: guid.rawValue)

    let source: AnyObject = try {
      let container = (try? IMCoreRuntime.send(item, "_imMessageItem")) ?? item
      guard let items = try? IMCoreRuntime.send(container, "_newChatItems") else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "message \(guid.rawValue) exposes no chat items"
        )
      }
      // A balloon message is a single IMTranscriptPluginChatItem, never an array.
      let candidate = (items as? [AnyObject])?.first ?? items
      guard let dataSource = try? IMCoreRuntime.send(candidate, "dataSource") else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "message \(guid.rawValue) is not a plugin message, so it has no media"
        )
      }
      return dataSource
    }()

    // Digital Touch generates on demand; handwriting is already on disk. Distinguished
    // by whether the data source can generate, rather than by class name, so a plugin
    // this port has not seen still works if it follows the same shape.
    if IMCoreRuntime.responds(source, to: NSSelectorFromString("generateMedia:")) {
      let once = ResumeOnce<Void>()
      let block: @convention(block) () -> Void = { once.finish() }
      do {
        try IMCoreRuntime.invoke(
          source, "generateMedia:", [unsafeBitCast(block, to: AnyObject.self)]
        )
      } catch {
        once.finish()
      }
      await once.wait()
    }

    return try translating {
      guard let url = try IMCoreRuntime.send(source, "assetURL"),
        let path = ((try? IMCoreRuntime.string(url, "path")) ?? nil),
        !path.isEmpty
      else {
        throw PrivateAPIErrorShim.rejected(
          "the plugin produced no media for \(guid.rawValue)"
        )
      }
      return path
    }
  }
}
