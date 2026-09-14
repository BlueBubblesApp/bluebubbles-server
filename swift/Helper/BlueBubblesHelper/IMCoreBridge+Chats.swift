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
  ) async throws -> ChatIdentifier {
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

      if let message, !message.isEmpty {
        let outgoing = try IMMessageBuilder.message(
          text: NSAttributedString(string: message),
          subject: nil, fileTransferGUIDs: [], effectID: nil,
          threadIdentifier: nil, isAudioMessage: false
        )
        try IMChat(created).send(outgoing)
      }
      return ChatIdentifier(guid)
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
  /// A READ of the same list `setPinned` already computes from, extracted because pins are
  /// the kind of state a user expects to follow them between devices and there was no way to
  /// ask for it. Nothing in the reference does this: the shipping helper only writes.
  ///
  /// **Order is the payload, not incidental.** Pinned conversations display in the order of
  /// this list, so a client syncing pins has to preserve it; returning a set would let the
  /// user's arrangement reshuffle on every sync.
  ///
  /// Two paths, matching the write. The modern one hands back `IMChat` objects, so their
  /// GUIDs come straight off them. The older one stores `pinningIdentifier` STRINGS, which
  /// are not chat GUIDs and cannot be turned into one by string manipulation, so each is
  /// resolved by asking the registry for the chat and comparing its own identifier. That is
  /// a lookup per pin rather than per chat, and people pin a handful of conversations.
  ///
  /// An identifier that resolves to nothing is DROPPED rather than reported as a null GUID:
  /// it means a pinned conversation the registry no longer has, which is stale state on
  /// Apple's side and not something a client can do anything with.
  public func pinnedChats() async throws -> [ChatIdentifier] {
    try translating {
      let controller = try IMCoreRuntime.sharedInstance(
        ofClass: "IMPinnedConversationsController"
      )

      if IMCoreRuntime.responds(
        controller, to: NSSelectorFromString("pinnedChats")
      ) {
        let chats = (try? IMCoreRuntime.objects(controller, "pinnedChats")) ?? []
        return chats.compactMap { chat -> ChatIdentifier? in
          guard let guid = (try? IMCoreRuntime.string(chat, "guid")) ?? nil
          else { return nil }
          return ChatIdentifier(guid)
        }
      }

      guard
        IMCoreRuntime.responds(
          controller, to: NSSelectorFromString("pinnedConversationIdentifierSet")
        )
      else {
        throw PrivateAPIError.unavailableOnThisOS(
          method: "pinnedChats",
          requires: "an IMPinnedConversationsController read selector this macOS has"
        )
      }

      let currentSet = try IMCoreRuntime.send(controller, "pinnedConversationIdentifierSet")
      let identifiers =
        ((try? currentSet.map { try IMCoreRuntime.objects($0, "array") })
        ?? []).compactMap { $0 as? String }

      return identifiers.compactMap { identifier in
        guard let chat = try? IMChatRegistry.chat(guid: identifier),
          let guid = (try? IMCoreRuntime.string(chat.object, "guid")) ?? nil
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
  /// The WRITE, though, is where the reference is out of date, and this is the case the
  /// selector tests exist to catch. `setPinnedConversationIdentifiers:withUpdateReason:`
  /// (what the shipping helper calls) no longer exists on macOS 26; Apple replaced it with
  /// `setPinnedChats:withUpdateReason:`, which takes IMChat objects rather than identifier
  /// strings. So both are attempted, newest first, and a macOS with neither says so rather
  /// than reporting a pin that did not happen.
  ///
  /// Order is preserved throughout: pinned conversations display in the order of this
  /// list, so rebuilding it as a set would reshuffle the user's pins whenever one changed.
  public func setPinned(chat: ChatIdentifier, pinned: Bool) async throws {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      let controller = try IMCoreRuntime.sharedInstance(
        ofClass: "IMPinnedConversationsController"
      )

      // Modern: the controller works in chats.
      if IMCoreRuntime.responds(
        controller, to: NSSelectorFromString("setPinnedChats:withUpdateReason:")
      ) {
        var chats = ((try? IMCoreRuntime.objects(controller, "pinnedChats")) ?? [])
        let alreadyPinned = chats.contains { $0 === conversation.object }
        if pinned {
          guard !alreadyPinned else { return }
          chats.append(conversation.object)
        } else {
          chats.removeAll { $0 === conversation.object }
        }
        // "contextMenu" is the reason the shipping helper sends. Messages branches on
        // it, so an invented string is not equivalent.
        try IMCoreRuntime.invoke(
          controller, "setPinnedChats:withUpdateReason:", [chats, "contextMenu"]
        )
        return
      }

      // The era the reference implementation targets: identifier strings.
      guard
        IMCoreRuntime.responds(
          controller,
          to: NSSelectorFromString("setPinnedConversationIdentifiers:withUpdateReason:")
        )
      else {
        throw PrivateAPIError.unavailableOnThisOS(
          method: "setPinned",
          requires: "an IMPinnedConversationsController write selector this macOS has"
        )
      }
      guard
        let identifier =
          ((try? IMCoreRuntime.string(
            conversation.object, "pinningIdentifier"
          )) ?? nil), !identifier.isEmpty
      else {
        throw PrivateAPIErrorShim.rejected("that conversation has no pinning identifier")
      }

      let currentSet = try IMCoreRuntime.send(controller, "pinnedConversationIdentifierSet")
      var identifiers =
        ((try? currentSet.map { try IMCoreRuntime.objects($0, "array") })
        ?? []).compactMap { $0 as? String }

      if pinned {
        guard !identifiers.contains(identifier) else { return }
        identifiers.append(identifier)
      } else {
        identifiers.removeAll { $0 == identifier }
      }
      try IMCoreRuntime.invoke(
        controller,
        "setPinnedConversationIdentifiers:withUpdateReason:",
        [identifiers, "contextMenu"]
      )
    }
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
