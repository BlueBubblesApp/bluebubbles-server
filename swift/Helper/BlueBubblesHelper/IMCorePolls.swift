//  IMCorePolls
//  Polls, the newest and least stable of these surfaces.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ImageIO
import ObjectiveC.runtime

// MARK: - Polls

/// Creating a poll and voting on one, the way the Polls extension does through Messages.
///
/// `docs/POLLS.md` is the reference. A poll is an app message: an `MSMessage` whose `URL`
/// is a `data:` URL of JSON, sent through ChatKit's `+[CKComposition
/// compositionWithMSMessage:appExtensionIdentifier:]`, which resolves the plugin, its icon
/// and its balloon bundle id and hands back a composition to send like any other. A vote is
/// a custom acknowledgement: `_MSMessageCustomAcknowledgement` produces the payload and
/// `+[IMMessage customAcknowledgementMessageWithPayloadData:…]` the message.
///
/// `Messages.framework` (the public iMessage-app API) is not necessarily loaded in
/// Messages.app until an extension runs, so it is `dlopen`ed on first use from its public
/// path: the one place in this helper a framework is loaded explicitly.
enum IMPolls {

  private static let frameworkPath =
    "/System/iOSSupport/System/Library/Frameworks/Messages.framework/Messages"

  private static func requireMessagesClass(_ name: String) throws -> AnyClass {
    if let found = IMCoreRuntime.lookUpClass(name) { return found }
    _ = dlopen(frameworkPath, RTLD_NOW)
    return try IMCoreRuntime.requireClass(name)
  }

  private static func allocate(_ type: AnyClass) throws -> AnyObject {
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("could not allocate \(type)")
    }
    return allocated
  }

  /// The local account's address, which the JSON names as `creatorHandle` and
  /// `participantHandle`.
  static func ownHandle() throws -> String {
    guard let handle = IMAccountController.loginHandle(),
      let id = ((try? IMCoreRuntime.string(handle, "ID")) ?? nil), !id.isEmpty
    else {
      throw PrivateAPIErrorShim.rejected("no iMessage login handle: is Messages signed in?")
    }
    return id
  }

  /// `data:,<base64 JSON>` with Messages' own query suffix on a poll (`?src=p&c=<n>`).
  static func dataURL(json: [String: Any], suffix: String = "") throws -> NSURL {
    let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    guard let url = NSURL(string: "data:," + data.base64EncodedString() + suffix) else {
      throw PrivateAPIErrorShim.rejected("could not build the poll data URL")
    }
    return url
  }

  static func pollJSON(title: String, options: [PollOptionSpec], creator: String) -> [String: Any] {
    [
      "version": 1,
      "item": [
        "title": title,
        "creatorHandle": creator,
        "orderedPollOptions": options.map { option -> [String: Any] in
          [
            "optionIdentifier": option.id,
            "text": option.text,
            "attributedText": option.text,
            "canBeEdited": option.canBeEdited,
            "creatorHandle": option.creatorHandle ?? creator,
          ]
        },
      ] as [String: Any],
    ]
  }

  static func votesJSON(optionIDs: [String], voter: String) -> [String: Any] {
    [
      "version": 1,
      "item": [
        "votes": optionIDs.map { ["participantHandle": voter, "voteOptionIdentifier": $0] }
      ] as [String: Any],
    ]
  }

  /// The composition for a new poll. ChatKit does the archive, the icon and the plugin
  /// lookup; the caller sends it like any composition.
  static func composition(title: String, options: [String]) throws -> AnyObject {
    let creator = try ownHandle()
    let specs = options.map {
      PollOptionSpec(id: UUID().uuidString, text: $0, creatorHandle: creator)
    }
    return try composition(title: title, options: specs, creator: creator, session: nil)
  }

  /// The composition for a poll re-sent in a new state: the SAME session, so ChatKit files
  /// it as an update of the original rather than a new poll. Options added by this account
  /// carry its handle; the ones already there keep their creators.
  static func updateComposition(_ request: PollUpdateRequest) throws -> AnyObject {
    let own = try ownHandle()
    guard let uuid = UUID(uuidString: request.sessionID) else {
      throw PrivateAPIErrorShim.rejected("the poll session id is not a UUID")
    }
    let specs = request.options.map {
      PollOptionSpec(
        id: $0.id, text: $0.text, creatorHandle: $0.creatorHandle ?? own,
        canBeEdited: $0.canBeEdited)
    }
    return try composition(
      title: request.title, options: specs, creator: request.creatorHandle ?? own,
      session: uuid)
  }

  /// The UPDATE message for a poll re-sent in a new state, ready for `sendMessage:`.
  ///
  /// MEASURED twice before this: the same session alone lands as a second poll, and so
  /// does naming the root on the composition's plugin payload: `IMPluginPayload.isUpdate`
  /// is a bare ivar with no setter, filled in only when the extension host builds the
  /// payload. So the update branch of `-[CKComposition(IMSuperFormat)
  /// _messageFromPayload:firstGUID:]` is reproduced here instead: the payload the
  /// composition built, handed to `+[IMMessage breadcrumbMessageWithText:
  /// associatedMessageGUID:balloonBundleID:fileTransferGUIDs:payloadData:threadIdentifier:]`,
  /// which writes `associatedMessageType` 2 (disassembled: `mov w8, #2`, flags 5) against the
  /// root. That is the row Messages' own "Add Choice" produces.
  static func updateMessage(_ request: PollUpdateRequest) throws -> AnyObject {
    let composition = try updateComposition(request)
    guard let payload = try IMCoreRuntime.send(composition, "shelfPluginPayload"),
      let data = try IMCoreRuntime.send(payload, "data")
    else {
      throw PrivateAPIErrorShim.rejected("the poll composition carries no plugin payload")
    }
    guard
      let text = try IMCoreRuntime.invoke(composition, "superFormatText:", [NSNull()])
        as? NSAttributedString
    else {
      throw PrivateAPIErrorShim.rejected("the poll composition produced no message text")
    }
    let messageClass: AnyClass = try IMCoreRuntime.requireClass("IMMessage")
    guard
      let message = try IMCoreRuntime.invoke(
        messageClass as AnyObject,
        "breadcrumbMessageWithText:associatedMessageGUID:balloonBundleID:fileTransferGUIDs:"
          + "payloadData:threadIdentifier:",
        [text, request.rootGUID.rawValue, PollsApp.balloonBundleID, NSNull(), data, NSNull()])
    else {
      throw PrivateAPIErrorShim.rejected("IMMessage would not build the poll update")
    }
    return message
  }

  private static func composition(
    title: String, options: [PollOptionSpec], creator: String, session uuid: UUID?
  ) throws -> AnyObject {
    let url = try dataURL(
      json: pollJSON(title: title, options: options, creator: creator),
      suffix: "?src=p&c=\(options.count)"
    )

    let sessionClass: AnyClass = try requireMessagesClass("MSSession")
    let session: AnyObject? =
      if let uuid {
        try IMCoreRuntime.invoke(
          try allocate(sessionClass), "initWithIdentifier:", [uuid as NSUUID])
      } else {
        try IMCoreRuntime.invoke(try allocate(sessionClass), "init")
      }
    guard let session else {
      throw PrivateAPIErrorShim.rejected("MSSession would not initialise")
    }
    let messageClass: AnyClass = try requireMessagesClass("MSMessage")
    guard
      let message = try IMCoreRuntime.invoke(
        try allocate(messageClass), "initWithSession:", [session])
    else {
      throw PrivateAPIErrorShim.rejected("MSMessage would not initialise")
    }
    try IMCoreRuntime.invoke(message, "setURL:", [url])
    // A LIVE layout wrapping the template, not the template alone. MEASURED: a poll sent
    // with only `MSMessageTemplateLayout` arrives as a plain balloon reading "Sent a poll"
    // with an "Add Choice" button and no options: the transcript falls back to the
    // template because the archive has no `liveLayoutInfo`. Apple's polls carry one
    // (`{layoutClass: MSMessageLiveLayout}`), which `MSMessage` writes itself when its
    // layout is an `MSMessageLiveLayout`; the template becomes the `alternateLayout` and
    // still supplies the caption other devices show while the poll loads.
    let templateClass: AnyClass = try requireMessagesClass("MSMessageTemplateLayout")
    guard let template = try IMCoreRuntime.invoke(try allocate(templateClass), "init") else {
      throw PrivateAPIErrorShim.rejected("MSMessageTemplateLayout would not initialise")
    }
    _ = try? IMCoreRuntime.invoke(template, "setCaption:", ["Sent a poll"])
    let liveClass: AnyClass = try requireMessagesClass("MSMessageLiveLayout")
    guard
      let live = try IMCoreRuntime.invoke(
        try allocate(liveClass), "initWithAlternateLayout:", [template])
    else {
      throw PrivateAPIErrorShim.rejected("MSMessageLiveLayout would not initialise")
    }
    try IMCoreRuntime.invoke(message, "setLayout:", [live])
    _ = try? IMCoreRuntime.invoke(message, "setSummaryText:", ["Sent a poll"])

    let compositionClass: AnyClass = try IMCoreRuntime.requireClass("CKComposition")
    guard
      let composition = try IMCoreRuntime.invoke(
        compositionClass as AnyObject, "compositionWithMSMessage:appExtensionIdentifier:",
        [message, PollsApp.extensionIdentifier])
    else {
      throw PrivateAPIErrorShim.rejected(
        "ChatKit would not build a composition for the Polls extension: is it installed?")
    }
    return composition
  }

  /// The vote message, ready for `-[IMChat sendMessage:]`.
  ///
  /// Transcribed from `-[CKCoreChatController transcriptCollectionViewController:
  /// balloonViewDidRequestSendCustomAcknowledgementPayload:forPlugin:error:]`: the
  /// acknowledgement's archived payload, the poll-state GUID it answers (bare; ChatKit
  /// prefixes `bp:` only to look the chat item up), the Polls bundle id, and a summary
  /// carrying what the notification shows. `configureMessageSummaryInfoForChatItem:` wants
  /// a ChatKit chat item; the four keys it produces for a vote are written directly.
  static func voteMessage(_ request: PollVoteRequest) throws -> AnyObject {
    let voter = try ownHandle()
    guard let uuid = UUID(uuidString: request.sessionID) else {
      throw PrivateAPIErrorShim.rejected("the poll session id is not a UUID")
    }
    let sessionClass: AnyClass = try requireMessagesClass("MSSession")
    guard
      let session = try IMCoreRuntime.invoke(
        try allocate(sessionClass), "initWithIdentifier:", [uuid as NSUUID])
    else {
      throw PrivateAPIErrorShim.rejected("MSSession would not initialise")
    }
    let ackClass: AnyClass = try requireMessagesClass("_MSMessageCustomAcknowledgement")
    guard
      let ack = try IMCoreRuntime.invoke(
        try allocate(ackClass), "initWithSession:isFromMe:time:", [session, true, NSDate()])
    else {
      throw PrivateAPIErrorShim.rejected("the acknowledgement would not initialise")
    }
    try IMCoreRuntime.invoke(
      ack, "setURL:", [try dataURL(json: votesJSON(optionIDs: request.optionIDs, voter: voter))])
    guard
      let payload = try IMCoreRuntime.invoke(
        ack, "_payloadDataFromAppName:adamID:", [PollsApp.appName, NSNull()])
    else {
      throw PrivateAPIErrorShim.rejected("the acknowledgement produced no payload")
    }

    let summary: [String: Any] = [
      "amc": 9,
      "ams": "Sent a vote",
      "amb": PollsApp.balloonBundleID,
      "amd": PollsApp.appName,
    ]
    let messageClass: AnyClass = try IMCoreRuntime.requireClass("IMMessage")
    guard
      let message = try IMCoreRuntime.invoke(
        messageClass as AnyObject,
        "customAcknowledgementMessageWithPayloadData:associatedMessageGUID:balloonBundleID:"
          + "messageSummaryInfo:threadIdentifier:",
        [payload, request.stateGUID.rawValue, PollsApp.balloonBundleID, summary, NSNull()])
    else {
      throw PrivateAPIErrorShim.rejected("IMMessage would not build the vote")
    }
    return message
  }
}
