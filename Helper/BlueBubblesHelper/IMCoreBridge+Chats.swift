//  IMCoreBridge+Chats
//  The conversation itself: creating one, its participants, its name, its photo, and
//  whether it is pinned. `ChatAdministration`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  /// PORTED. ObjC: resolve each address to an IMHandle, then `chatForIMHandles:`.
  ///
  /// The chat is created LOCALLY and nothing is transmitted until a message is sent, which
  /// is why `message` is optional and why sending it is part of the same call: a caller
  /// that wanted a conversation to exist for the other party has to send something.
  public func createChat(
    addresses: [String], service: String, message: String?
  ) async throws -> NewChat {
    try translating {
      guard !addresses.isEmpty else {
        throw PrivateAPIErrorShim.rejected("a chat needs at least one address")
      }

      let handles = try addresses.map { address -> IMHandle in
        guard
          let handle = try IMAccountController.handle(
            for: address, service: service
          )
        else {
          throw PrivateAPIErrorShim.rejected(
            "no \(service) handle for \(address): the address may not be reachable "
              + "on this service"
          )
        }
        return handle
      }

      let registry = try IMCoreRuntime.sharedInstance(ofClass: "IMChatRegistry")
      guard
        let created = try IMCoreRuntime.invoke(
          registry, "chatForIMHandles:", [handles.map(\.object)]
        )
      else {
        throw PrivateAPIErrorShim.rejected("IMCore would not create a chat")
      }

      guard let guid = try IMCoreRuntime.string(created, "guid") else {
        throw PrivateAPIErrorShim.rejected("the new chat reported no GUID")
      }

      let chat = ChatIdentifier(guid)
      guard let message, !message.isEmpty else {
        return NewChat(chat: chat, firstMessage: nil)
      }
      let messageGUID = IMMessageBuilder.newGUID()
      let outgoing = try IMMessageBuilder.message(
        text: NSAttributedString(string: message),
        subject: nil, fileTransferGUIDs: [], effectID: nil, isAudioMessage: false,
        guid: messageGUID
      )
      try IMChat(created).send(outgoing)
      let sent = try sent(
        [outgoing], to: chat, assignedGUID: messageGUID, sending: "first message")
      return NewChat(chat: chat, firstMessage: sent.guid)
    }
  }

  /// PORTED. ObjC: `[[CKConversationList sharedConversationList] deleteConversation:]`
  /// (BlueBubblesHelper.m:602).
  ///
  /// Through the CONVERSATION LIST, which is what actually removes a conversation. Not
  /// `deleteAllHistory`, which empties a chat and leaves it in the list, and not
  /// `IMChatRegistry._chat_remove:`, which unregisters the in-memory object without deleting
  /// anything.
  public func deleteChat(_ chat: ChatIdentifier) async throws {
    try translating {
      let conversation = try requireConversation(chat)
      let type: AnyClass = try IMCoreRuntime.requireClass("CKConversationList")
      guard
        let list = try IMCoreRuntime.send(
          type as AnyObject, "sharedConversationList"
        )
      else {
        throw PrivateAPIErrorShim.rejected("could not reach the conversation list")
      }
      try IMCoreRuntime.invoke(list, "deleteConversation:", [conversation.object])
    }
  }

  /// PORTED. ObjC: `[chat leave]`.
  public func leaveChat(_ chat: ChatIdentifier) async throws {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).leave()
    }
  }

  /// PORTED. ObjC: `[chat _setDisplayName:]` (BlueBubblesHelper.m:239).
  public func setDisplayName(chat: ChatIdentifier, to name: String) async throws {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).setDisplayName(name)
    }
  }

  /// PORTED. ObjC: `[chat sendGroupPhotoUpdate:]` (BlueBubblesHelper.m:560).
  ///
  /// Takes a TRANSFER GUID, not an image. An earlier pass passed an `NSImage`, which the
  /// runtime accepts and Messages ignores: the photo silently never changes. The file
  /// goes through the same registration as any attachment, because that is what it is.
  ///
  /// An empty path clears the photo, which is how the reference distinguishes the two.
  public func updateGroupPhoto(chat: ChatIdentifier, imagePath: String) async throws {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      guard !imagePath.isEmpty else {
        try IMCoreRuntime.invoke(
          conversation.object, "sendGroupPhotoUpdate:", [NSNull()]
        )
        return
      }
      guard FileManager.default.fileExists(atPath: imagePath) else {
        throw PrivateAPIErrorShim.rejected("no image at \(imagePath)")
      }
      let prepared = try IMFileTransfers.register(path: imagePath)
      try IMCoreRuntime.invoke(
        conversation.object, "sendGroupPhotoUpdate:", [prepared.guid]
      )
    }
  }

  /// PORTED. ObjC: `updateParticipantsForChat:…isAdding:YES` (BlueBubblesHelper.m:245).
  ///
  /// Goes through ChatKit rather than IMChat, because ChatKit is what enforces the
  /// recipient limit, and IMCore's own add silently does nothing when the group is full.
  public func addParticipant(_ address: String, to chat: ChatIdentifier) async throws {
    try translating {
      let conversation = try requireConversation(chat)
      guard try conversation.canInsertMoreRecipients() else {
        throw PrivateAPIErrorShim.rejected(
          "That group cannot take another participant."
        )
      }
      guard let handle = try IMAccountController.handle(for: address) else {
        throw PrivateAPIErrorBridge.noSuchHandle(address)
      }
      try conversation.addRecipient(handle)
    }
  }

  /// PORTED. ObjC: `updateParticipantsForChat:…isAdding:NO` (BlueBubblesHelper.m:245).
  public func removeParticipant(_ address: String, from chat: ChatIdentifier) async throws {
    try translating {
      let conversation = try requireConversation(chat)
      guard let handle = try IMAccountController.handle(for: address) else {
        throw PrivateAPIErrorBridge.noSuchHandle(address)
      }
      try conversation.removeRecipient(handle)
    }
  }

  /// The pinned conversations, in display order.
  ///
  /// A READ of the same list `setPinned` computes from, extracted because pins are the kind
  /// of state a user expects to follow them between devices and there was no way to ask for
  /// it. Nothing in the reference does this: the shipping helper only writes.
  ///
  /// **Order is the payload, not incidental.** Pinned conversations display in the order of
  /// this list, so a client syncing pins has to preserve it; returning a set would let the
  /// user's arrangement reshuffle on every sync.
  ///
  /// The controller stores `pinningIdentifier` STRINGS, which are not chat GUIDs and cannot
  /// be turned into one by string manipulation, so each is resolved through the registry's
  /// own pinning-identifier lookup. That is a lookup per pin rather than per chat, and people
  /// pin a handful of conversations.
  ///
  /// An identifier that resolves to nothing is DROPPED rather than reported as a null GUID:
  /// it means a pinned conversation the registry no longer has, which is stale state on
  /// Apple's side and not something a client can do anything with.
  public func pinnedChats() async throws -> [ChatIdentifier] {
    try translating {
      try Self.pinnedIdentifiers().compactMap { identifier in
        guard let chat = try IMChatRegistry.chat(pinningIdentifier: identifier),
          let guid = try IMCoreRuntime.string(chat.object, "guid")
        else { return nil }
        return ChatIdentifier(guid)
      }
    }
  }

  /// PORTED. ObjC: `update-chat-pinned` (BlueBubblesHelper.m:388).
  ///
  /// The identifier is `pinningIdentifier`, NOT the chat GUID. They are different strings,
  /// and pinning by GUID writes an entry macOS does not recognise: the pin silently never
  /// appears. That one is from the reference implementation; it is not guessable.
  ///
  /// The WRITE is `setPinnedChats:withUpdateReason:`, which REPLACES the whole list and
  /// takes `IMChat` objects. The controller has no matching read of chats (there is no
  /// `pinnedChats` on 14.6.1 through 27.0.1, per `docs/headers/`), so the current list is
  /// read as identifiers and each is resolved back to its chat before writing. Every read
  /// failure throws: a list that came back short would be written over the user's pins.
  /// For the same reason a pinned identifier the registry cannot resolve refuses the
  /// change rather than being dropped from the list.
  ///
  /// Order is preserved throughout: pinned conversations display in the order of this
  /// list, so rebuilding it as a set would reshuffle the user's pins whenever one changed.
  public func setPinned(chat: ChatIdentifier, pinned: Bool) async throws {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      guard
        let target = try IMCoreRuntime.string(conversation.object, "pinningIdentifier"),
        !target.isEmpty
      else {
        throw PrivateAPIErrorShim.rejected("that conversation has no pinning identifier")
      }

      var identifiers = try Self.pinnedIdentifiers()
      if pinned {
        guard !identifiers.contains(target) else { return }
        identifiers.append(target)
      } else {
        guard identifiers.contains(target) else { return }
        identifiers.removeAll { $0 == target }
      }

      let chats: [AnyObject] = try identifiers.map { identifier in
        if identifier == target { return conversation.object }
        guard let chat = try IMChatRegistry.chat(pinningIdentifier: identifier) else {
          throw PrivateAPIErrorShim.rejected(
            "another pinned conversation could not be found, so changing the pins would "
              + "unpin it")
        }
        return chat.object
      }

      let controller = try IMCoreRuntime.sharedInstance(
        ofClass: "IMPinnedConversationsController"
      )
      // "contextMenu" is the reason the shipping helper sends. Messages branches on it, so
      // an invented string is not equivalent.
      try IMCoreRuntime.invoke(
        controller, "setPinnedChats:withUpdateReason:", [chats, "contextMenu"]
      )
    }
  }

  /// The pinned conversations' identifiers, in display order. Throws rather than answering
  /// empty, because `setPinned` writes what this returns back over the user's pins.
  private static func pinnedIdentifiers() throws -> [String] {
    let controller = try IMCoreRuntime.sharedInstance(
      ofClass: "IMPinnedConversationsController"
    )
    // An NSOrderedSet; `array` keeps its order. A nil set is the controller saying there
    // are no pins, which is the one empty answer that is true.
    guard let set = try IMCoreRuntime.send(controller, "pinnedConversationIdentifierSet")
    else { return [] }
    return try IMCoreRuntime.objects(set, "array").compactMap { $0 as? String }
  }

  /// PORTED. ObjC: `[chat refetchLocalTranscriptBackgroundAssetIfNecessary]`.
  ///
  /// Returns as soon as the daemon has been asked. See the contract for why there is
  /// nothing to await here.
  public func refetchChatBackground(chat: ChatIdentifier) async throws {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).refetchTranscriptBackground()
    }
  }
}
