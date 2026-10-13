//  IMCoreConversationUI
//  What Messages' own transcript would present for a conversation.
//
//  IMCore answers where a chat SITS (filtered, category, known sender). ChatKit answers what
//  the UI DOES about it, and those are different questions: `-shouldPresentSpamReasonPicker`
//  is the one the transcript asks before offering to report a conversation, and nothing on
//  `IMChat` answers it. A client that wants to behave like the Messages window needs the
//  second question, not a reconstruction of it from the first.
//
//  `CKConversation` wraps an `IMChat` and is vended by
//  `+[CKConversationList sharedConversationList] -conversationForExistingChat:`. Both the
//  list and the accessor are on 14.6.1, 15.6.1 and 26.5.2; the individual signals are not,
//  so every one is optional and absent means "this release cannot say" rather than `false`.
//
//  ## Why this is read through the UI layer at all
//
//  Because the UI layer is where the answer lives, and because the helper is injected into
//  Messages.app itself: ChatKit is already loaded, already has the conversation list this
//  window is showing, and is asking about the same objects the person at the Mac sees.
//
//  ## `conversationForExistingChat:`, not `conversationForChat:`
//
//  `CKConversationList` has several vendors and they are not equivalent.
//  `-_conversationForChat:` and `-_beginTrackingConversationWithChat:completion:` have names
//  that say they CREATE and TRACK; `-conversationForExistingChat:` says it wants one that is
//  already there. Reading state must not bring a conversation into existence or enrol it in
//  anything, so the existing-only accessor is the one used, and a chat the list does not
//  already know about answers nil rather than being conjured.

import BBPrivateAPIContract
import Foundation
import HelperShared
import ObjectiveC.runtime

enum IMCoreConversationUI {

  /// The ChatKit conversation for a chat, or nil when ChatKit does not already have one.
  ///
  /// Nil is a real answer and is reported as one: every field of `ChatPresentationState`
  /// becomes nil, which says "not known" rather than "no".
  @MainActor
  static func conversation(for chat: IMChat) throws -> AnyObject? {
    guard
      let list = try? IMCoreRuntime.sharedInstance(
        ofClass: "CKConversationList", accessors: ["sharedConversationList"]
      )
    else { return nil }
    guard
      IMCoreRuntime.responds(list, to: "conversationForExistingChat:")
    else { return nil }
    return try IMCoreRuntime.send(list, "conversationForExistingChat:", chat.object)
  }

  /// Every signal the transcript would consult, each optional.
  ///
  /// `try?` per field rather than one throwing read, because the releases differ field by
  /// field: on 14 the picker and the load flag are absent while the detection flags are
  /// present, and losing the whole answer to one missing selector is the failure
  /// `filterState()` already avoids.
  @MainActor
  static func presentationState(for chat: IMChat) throws -> ChatPresentationState {
    let filteringEnabled = classLevelFlag(
      onClass: "CKConversation", selector: "isSMSSpamFilteringEnabled")

    guard let conversation = try conversation(for: chat) else {
      // No conversation: every per-chat answer is unknown. The class-level flag still
      // stands, because it is about the feature rather than about this chat.
      return ChatPresentationState(
        shouldPresentSpamReasonPicker: nil,
        isReportedAsSpam: nil,
        wasDetectedAsSMSSpam: nil,
        wasDetectedAsSpam: nil,
        isKnownChat: nil,
        completedInitialChatMessagesLoad: nil,
        isSMSSpamFilteringEnabled: filteringEnabled
      )
    }

    return ChatPresentationState(
      shouldPresentSpamReasonPicker: flag(conversation, "shouldPresentSpamReasonPicker"),
      isReportedAsSpam: flag(conversation, "isReportedAsSpam"),
      // Declared `int` rather than `bool` on every release, so it is read as an integer and
      // compared, not cast: a BOOL read of a four-byte return is the class of mistake
      // `IMCoreRuntime.bool` exists to refuse.
      wasDetectedAsSMSSpam: integerFlag(conversation, "wasDetectedAsSMSSpam"),
      wasDetectedAsSpam: integerFlag(conversation, "wasDetectedAsSpam"),
      isKnownChat: flag(conversation, "isKnownChat"),
      completedInitialChatMessagesLoad: flag(conversation, "completedInitialChatMessagesLoad"),
      isSMSSpamFilteringEnabled: filteringEnabled
    )
  }

  /// A BOOL selector, or nil when this release does not have it.
  @MainActor
  private static func flag(_ target: AnyObject, _ selector: String) -> Bool? {
    guard IMCoreRuntime.responds(target, to: selector) else { return nil }
    return try? IMCoreRuntime.bool(target, selector)
  }

  /// An `int` selector read as a flag: non-zero is true.
  @MainActor
  private static func integerFlag(_ target: AnyObject, _ selector: String) -> Bool? {
    guard IMCoreRuntime.responds(target, to: selector) else { return nil }
    guard let value = try? IMCoreRuntime.integer(target, selector) else { return nil }
    return value != 0
  }

  @MainActor
  private static func classLevelFlag(onClass name: String, selector: String) -> Bool? {
    guard let type = IMCoreRuntime.lookUpClass(name) else { return nil }
    let object = type as AnyObject
    guard IMCoreRuntime.responds(object, to: selector) else { return nil }
    return try? IMCoreRuntime.bool(object, selector)
  }
}
