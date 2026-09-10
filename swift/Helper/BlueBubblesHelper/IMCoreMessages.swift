//  IMCoreMessages
//  Building an outgoing message: attributed text, subject, effect and reply metadata.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ImageIO
import ObjectiveC.runtime

// MARK: - Messages

/// `IMMessage`: one outgoing message.
///
/// Built through the eleven-argument designated initializer, which is why the invocation
/// bridge exists. Transcribed from `BlueBubblesHelper.m:1050`.
enum IMMessageBuilder {

  /// The flags word, and it is not arbitrary.
  ///
  /// These constants come from the shipping helper and encode what kind of message this
  /// is. Getting them wrong produces a message that sends and then renders incorrectly:
  /// an audio message that appears as a file, a subject that vanishes.
  enum Flags {
    /// A plain outgoing message.
    static let plain: Int64 = 0x100005
    /// Carries a subject line.
    static let withSubject: Int64 = 0x10000D
    /// An audio message, which Messages renders with a waveform.
    static let audio: Int64 = 0x300005
    /// A tapback. Note it is 0x5, not one of the above: an association is a different
    /// kind of message rather than a plain one with extra fields.
    static let association: Int64 = 0x5
  }

  /// A plain or attachment-bearing message.
  ///
  /// ObjC: `initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:`
  /// `subject:balloonBundleID:payloadData:expressiveSendStyleID:` (BlueBubblesHelper.m:1050).
  ///
  /// Note there are TWO subject parameters. `messageSubject` is the attributed subject that
  /// actually appears; the later `subject:` is a legacy field the shipping helper passes
  /// nil for. Passing the text in the wrong one silently drops it.
  /// A fresh `IMMessage` allocation, ready for one of its designated initializers.
  ///
  /// `alloc` through `perform` rather than `init`: every constructor below calls a
  /// designated initializer with a dozen arguments, and the allocation is the one step they
  /// share.
  private static func allocateMessage() throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("IMMessage")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("Could not allocate an IMMessage")
    }
    return allocated
  }

  static func message(
    text: NSAttributedString,
    subject: NSAttributedString?,
    fileTransferGUIDs: [String],
    effectID: String?,
    threadIdentifier: String?,
    isAudioMessage: Bool
  ) throws -> AnyObject {
    let allocated = try allocateMessage()

    let flags: Int64 =
      isAudioMessage
      ? Flags.audio
      : (subject != nil ? Flags.withSubject : Flags.plain)

    guard
      let message = try IMCoreRuntime.invoke(
        allocated,
        "initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:"
          + "subject:balloonBundleID:payloadData:expressiveSendStyleID:",
        [
          NSNull(),  // sender; nil means the local account
          NSNull(),  // time; nil means now
          text,
          subject ?? NSNull(),
          fileTransferGUIDs,
          flags,
          NSNull(),  // error
          NSNull(),  // guid; nil means Messages assigns one
          NSNull(),  // subject (legacy; see above)
          NSNull(),  // balloonBundleID
          NSNull(),  // payloadData
          effectID ?? NSNull(),
        ]
      )
    else {
      throw PrivateAPIErrorShim.rejected("IMMessage initializer returned nil")
    }

    // Reply threading. Set after construction because the initializer has no parameter
    // for it; ObjC: `messageToSend.threadIdentifier = threadIdentifier`.
    if let threadIdentifier {
      try IMCoreRuntime.invoke(message, "setThreadIdentifier:", [threadIdentifier])
    }
    return message
  }

  /// A tapback.
  ///
  /// ObjC: the `associatedMessageGUID:associatedMessageType:associatedMessageRange:`
  /// `messageSummaryInfo:` variant (BlueBubblesHelper.m:1053). A different initializer and
  /// a different flags word: an association is its own kind of message.
  static func association(
    text: NSAttributedString,
    associatedGUID: String,
    associatedType: Int64,
    range: NSRange,
    summaryInfo: [String: Any]?
  ) throws -> AnyObject {
    let allocated = try allocateMessage()

    guard
      let message = try IMCoreRuntime.invoke(
        allocated,
        "initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:"
          + "subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:"
          + "messageSummaryInfo:",
        [
          NSNull(), NSNull(), text, NSNull(), NSNull(),
          Flags.association,
          NSNull(), NSNull(), NSNull(),
          associatedGUID,
          associatedType,
          NSValue(range: range),
          summaryInfo ?? NSNull(),
        ]
      )
    else {
      throw PrivateAPIErrorShim.rejected("IMMessage association initializer returned nil")
    }
    return message
  }

  /// An iMessage-app balloon: a plain message carrying a plugin bundle id and its payload.
  ///
  /// The same eleven-argument initializer everything else uses, with the two arguments the
  /// text path passes nil for actually filled in. The TEXT is the fallback line a device
  /// shows when it cannot draw the balloon; Apple's own app messages carry an empty one and
  /// let the layout's caption speak, and that is what is sent when no summary is given.
  static func appMessage(
    balloonBundleID: String, payload: Data, summary: String?
  ) throws -> AnyObject {
    let allocated = try allocateMessage()
    guard
      let message = try IMCoreRuntime.invoke(
        allocated,
        "initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:"
          + "subject:balloonBundleID:payloadData:expressiveSendStyleID:",
        [
          NSNull(), NSNull(), NSAttributedString(string: summary ?? ""), NSNull(), [],
          Flags.plain, NSNull(), NSNull(), NSNull(),
          balloonBundleID, payload, NSNull(),
        ]
      )
    else {
      throw PrivateAPIErrorShim.rejected("IMMessage would not build the app message")
    }
    return message
  }

  /// A sticker: an association that also carries a file transfer.
  ///
  /// TRANSCRIBED from Messages' own send, `-[CKChatController(CKChatController_Stickers)
  /// _sendCommSafetyVerifiedSticker:withMediaObject:composition:parentMessagePartChatItem:
  /// messageSummaryInfo:]` on macOS 26.5.2 (disassembled; see `docs/PRIVATE_API_SURFACE.md`
  /// § Stickers). It is the fourteen-argument association initializer (the tapback one
  /// with `threadIdentifier:` on the end) called with:
  ///
  ///     sender nil · time [NSDate date] · text = composition superFormatText
  ///     messageSubject nil · fileTransferGUIDs from the composition · flags 5
  ///     error nil · guid [NSString stringGUID] · subject nil
  ///     associatedMessageGUID = parent part chat item's guid   ("p:0/<message guid>")
  ///     associatedMessageType = 1000 (1001 for an emoji sticker)
  ///     associatedMessageRange = parent part's messagePartRange
  ///     messageSummaryInfo = whatever the caller had (nil from the drag-and-drop path)
  ///     threadIdentifier = parent part's threadIdentifier
  ///
  /// Two of those are not what the tapback path passes and both matter. The RANGE is the
  /// part's real range in the message text, not `(partIndex, 1)`: chat.db shows every
  /// received sticker with the parent part's text length as its range length, and the
  /// sticker's geometry is expressed relative to that part. The GUID is the CHAT ITEM's,
  /// with the `p:<part>/` prefix, which is how Messages knows which balloon to draw it on.
  ///
  /// The thirteen-argument initializer is used when the fourteen-argument one is absent,
  /// which loses the thread identifier and nothing else.
  static func sticker(
    text: NSAttributedString,
    fileTransferGUIDs: [String],
    guid: String,
    associatedGUID: String,
    associatedType: Int64,
    range: NSRange,
    summaryInfo: [String: Any]?,
    threadIdentifier: String?
  ) throws -> AnyObject {
    let allocated = try allocateMessage()

    let base =
      "initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:"
      + "subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:"
      + "messageSummaryInfo:"
    var arguments: [Any] = [
      NSNull(), NSDate(), text, NSNull(), fileTransferGUIDs,
      Flags.association,
      NSNull(), guid, NSNull(),
      associatedGUID,
      associatedType,
      NSValue(range: range),
      summaryInfo ?? NSNull(),
    ]
    let selector: String
    if IMCoreRuntime.responds(allocated, to: NSSelectorFromString(base + "threadIdentifier:")) {
      selector = base + "threadIdentifier:"
      arguments.append(threadIdentifier ?? NSNull())
    } else {
      selector = base
    }

    guard let message = try IMCoreRuntime.invoke(allocated, selector, arguments) else {
      throw PrivateAPIErrorShim.rejected("IMMessage sticker initializer returned nil")
    }
    return message
  }
}
