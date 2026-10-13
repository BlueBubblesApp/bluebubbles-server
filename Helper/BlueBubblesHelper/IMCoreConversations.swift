//  IMCoreConversations
//  ChatKit's view of a chat: the conversation list the UI drives, and its controllers.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperObjC
import HelperShared
import ObjectiveC.runtime

struct CKConversation {
  let object: AnyObject
  init(_ object: AnyObject) { self.object = object }

  /// Whether the group has room for another participant.
  ///
  /// Checked BEFORE adding, because IMCore's own add silently does nothing when the group
  /// is full; ObjC: BlueBubblesHelper.m:254.
  func canInsertMoreRecipients() throws -> Bool {
    try IMCoreRuntime.bool(object, "canInsertMoreRecipients")
  }

  /// ObjC: `[chat addRecipientHandles:]` / `removeRecipientHandles:`
  /// (BlueBubblesHelper.m:263-266). Both take an ARRAY, even for one handle.
  func addRecipient(_ handle: IMHandle) throws {
    try IMCoreRuntime.invoke(object, "addRecipientHandles:", [[handle.object]])
  }

  func removeRecipient(_ handle: IMHandle) throws {
    try IMCoreRuntime.invoke(object, "removeRecipientHandles:", [[handle.object]])
  }

  /// Builds the messages a composition turns into.
  ///
  /// PLURAL, and that is the point. `messageWithComposition:` returns one message, but a
  /// composition carrying both text and media does not necessarily become one message:
  /// Messages splits it, which is why ChatKit also exposes `messagesFromComposition:`.
  /// Building with the singular and sending that is how an attachment goes missing while
  /// the text arrives: measured, with the composition demonstrably holding the media and
  /// the sent message carrying `cache_has_attachments = 0`.
  ///
  /// Falls back to the singular where the plural is absent.
  func messages(from composition: AnyObject) throws -> [AnyObject] {
    if IMCoreRuntime.responds(object, to: "messagesFromComposition:"),
      let produced = try? IMCoreRuntime.invoke(
        object, "messagesFromComposition:", [composition]
      ),
      let list = produced as? [AnyObject], !list.isEmpty
    {
      return list
    }
    guard
      let message = try IMCoreRuntime.invoke(
        object, "messageWithComposition:", [composition]
      )
    else {
      throw PrivateAPIErrorShim.rejected("ChatKit would not build a message")
    }
    return [message]
  }

  /// Whether ChatKit will accept this composition at all.
  ///
  /// Asked before sending because the send itself reports nothing: a composition it
  /// refuses produces no message, no error and no attachment.
  func canSend(_ composition: AnyObject) -> Bool {
    guard
      IMCoreRuntime.responds(
        object, to: "canSendComposition:error:"
      )
    else { return true }
    let result = try? IMCoreRuntime.invoke(
      object, "canSendComposition:error:", [composition, NSNull()]
    )
    return (result as? NSNumber)?.boolValue ?? true
  }

  /// ObjC: `[convo sendMessage:newComposition:YES]`.
  func send(_ message: AnyObject, newComposition: Bool = true) throws {
    try IMCoreRuntime.invoke(object, "sendMessage:newComposition:", [message, newComposition])
  }

  /// Read state lives on the CONVERSATION, not on IMChat (BlueBubblesHelper.m:384).
  func markAllMessagesAsRead() throws {
    try IMCoreRuntime.invoke(object, "markAllMessagesAsRead")
  }

  /// Ventura and later. The reference raises rather than silently doing nothing, and so
  /// does this: a caller that thinks it marked a chat unread and did not is worse off
  /// than one told the OS cannot.
  func markLastMessageAsUnread() throws {
    try IMCoreRuntime.requireResponding(object, to: "markLastMessageAsUnread")
    try IMCoreRuntime.invoke(object, "markLastMessageAsUnread")
  }

  /// ObjC: `editMessageItem:partIndex:withNewComposition:` (BlueBubblesHelper.m:1151).
  ///
  /// Takes a COMPOSITION, and only the new text: the separate
  /// backward-compatibility string the older IMChat selector wanted is gone. Two selector
  /// generations, newest first.
  func editMessage(item: AnyObject, partIndex: Int, composition: AnyObject) throws {
    let selector = try IMCoreRuntime.requireResponding(
      object,
      among: [
        "editMessageItem:partIndex:withNewComposition:",
        "editMessage:partIndex:withNewComposition:",
      ])
    try IMCoreRuntime.invoke(object, selector, [item, partIndex, composition])
  }

  /// ObjC: `[convo retractMessagePart:]` (BlueBubblesHelper.m:1166): "unsend".
  func retractMessagePart(_ part: AnyObject) throws {
    try IMCoreRuntime.invoke(object, "retractMessagePart:", [part])
  }
}

/// The IMCore attachment path: register a file transfer, then name it in the message.
///
/// This is what the shipping helper used for years before its ChatKit refactor, so the
/// approach is known to work.
///
/// The sequence is not guessable and every step fails quietly if skipped
/// (`prepareFileTransferForAttachment:filename:`, pre-refactor BlueBubblesHelper.m:967):
///
///   1. `guidForNewOutgoingTransferWithLocalURL:` mints a transfer GUID.
///   2. `_persistentPathForTransfer:…` asks the daemon WHERE the bytes must live, and the
///      file is copied there. The daemon will not keep a transfer pointing outside its own
///      store; the helper's own comment is "The file must be in correct location before
///      this".
///   3. `retargetTransfer:toPath:` points the transfer at the copy.
///   4. `registerTransferWithDaemon:` takes the GUID, not the transfer object.
///
/// Every step logs, because a silent no-op gives no hint which step was skipped.
