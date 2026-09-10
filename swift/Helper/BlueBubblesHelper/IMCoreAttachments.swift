//  IMCoreAttachments
//  Sending files: the transfer objects Messages moves, and the compositions that carry them.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ImageIO
import ObjectiveC.runtime

enum IMFileTransfers {

  struct Prepared {
    let guid: String
    let filename: String
  }

  static func center() throws -> AnyObject {
    try IMCoreRuntime.sharedInstance(
      ofClass: "IMFileTransferCenter",
      accessors: ["sharedInstance", "sharedCenter", "defaultCenter"]
    )
  }

  static func register(path: String, chatGUIDHint: String? = nil) throws -> Prepared {
    guard FileManager.default.fileExists(atPath: path) else {
      throw PrivateAPIErrorShim.rejected("no file at \(path)")
    }
    let center = try center()
    let source = URL(fileURLWithPath: path)
    let filename = source.lastPathComponent

    guard
      let guid = try IMCoreRuntime.send(
        center, "guidForNewOutgoingTransferWithLocalURL:", source as NSURL
      ) as? String
    else {
      throw PrivateAPIErrorShim.rejected(
        "IMFileTransferCenter would not create a transfer for \(path)"
      )
    }
    BlueBubblesHelper.Logging.log("imcore-attach: 1/4 transfer guid=\(guid)")

    guard let transfer = try IMCoreRuntime.send(center, "transferForGUID:", guid) else {
      throw PrivateAPIErrorShim.rejected("transfer \(guid) could not be read back")
    }

    // Step 2-3. Reported rather than silently skipped: a missing attachment gives no hint
    // which step lost it.
    do {
      let controller = try IMCoreRuntime.sharedInstance(
        ofClass: "IMDPersistentAttachmentController"
      )
      // MEASURED on macOS 26: the reference's `storeAtExternalPath:YES` returns nil,
      // and `NO` returns a real path inside Messages' container. The variants are kept
      // in this order because which one answers has changed between releases, and a
      // nil path is indistinguishable from a missing selector without trying.
      //
      // Getting a path is still not enough: copying into it is denied by the sandbox.
      // See `IMCoreBridge.sendAttachment`.
      var returned: Any?
      for (label, args) in [
        ("nil-chat/hq/external", [transfer, filename, true, NSNull(), true] as [Any]),
        ("nil-chat/hq/internal", [transfer, filename, true, NSNull(), false] as [Any]),
        ("nil-chat/sd/external", [transfer, filename, false, NSNull(), true] as [Any]),
        ("chat/hq/external", [transfer, filename, true, chatGUIDHint ?? NSNull(), true] as [Any]),
      ] {
        let candidate = try? IMCoreRuntime.invoke(
          controller,
          "_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:",
          args
        )
        BlueBubblesHelper.Logging.log(
          "imcore-attach: 2/4 variant \(label) -> \(String(describing: candidate))"
        )
        if let path = candidate as? String, !path.isEmpty {
          returned = path
          break
        }
      }
      guard let persistent = returned as? String, !persistent.isEmpty else {
        throw PrivateAPIErrorShim.rejected(
          "persistent path came back as \(String(describing: returned))"
        )
      }
      BlueBubblesHelper.Logging.log("imcore-attach: 2/4 persistent=\(persistent)")

      let destination = URL(fileURLWithPath: persistent)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: persistent) {
        try? FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)

      try IMCoreRuntime.invoke(center, "retargetTransfer:toPath:", [guid, persistent])
      _ = try? IMCoreRuntime.invoke(transfer, "setLocalURL:", [destination as NSURL])
      BlueBubblesHelper.Logging.log("imcore-attach: 3/4 copied and retargeted")
    } catch {
      // Loud, and NOT fatal: registering where the file stands is worth trying, and a
      // logged reason is what the last attempt lacked.
      BlueBubblesHelper.Logging.error(
        "imcore-attach: 2-3/4 FAILED: \(error). Registering in place."
      )
    }

    try IMCoreRuntime.invoke(center, "registerTransferWithDaemon:", [guid])
    BlueBubblesHelper.Logging.log(
      "imcore-attach: 4/4 registered; localPath="
        + String(describing: try? IMCoreRuntime.string(transfer, "localPath"))
    )
    return Prepared(guid: guid, filename: filename)
  }

  /// The attributed run standing in for the attachment.
  ///
  /// A bare U+FFFC is not enough: the character reserves the position and these attributes
  /// are what bind the transfer to it.
  static func attachmentRun(_ prepared: Prepared, partIndex: Int) -> NSAttributedString {
    NSAttributedString(
      string: "\u{FFFC}",
      attributes: [
        .init("__kIMFileTransferGUIDAttributeName"): prepared.guid,
        .init("__kIMFilenameAttributeName"): prepared.filename,
        .init("__kIMMessagePartAttributeName"): partIndex,
        .init("__kIMBaseWritingDirectionAttributeName"): "-1",
      ]
    )
  }

  static func textRun(_ text: String, mention: String?, partIndex: Int) -> NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [
      .init("__kIMBaseWritingDirectionAttributeName"): "-1",
      .init("__kIMMessagePartAttributeName"): partIndex,
    ]
    if let mention, !mention.isEmpty {
      attributes[.init("__kIMMentionConfirmedMention")] = mention
    }
    return NSAttributedString(string: text, attributes: attributes)
  }
}

/// ChatKit compositions: how a message with attachments is actually assembled.
///
/// Not raw IMCore: building an `IMMessage` directly and naming file transfers by GUID sends
/// the message and attaches nothing: verified against chat.db, where the message arrives
/// with `cache_has_attachments = 0` and no attachment row at all.
///
/// ChatKit is what Messages itself uses, and `CKMediaObjectManager` does the whole job:
/// transcoding, the persistent copy into the daemon's store, and registering the transfer.
/// Reproducing those steps by hand does not work; the shipping helper uses compositions
/// too.
enum CKCompositions {

  /// An empty composition, optionally with a subject.
  ///
  /// Empty rather than seeded with the text, because parts are appended IN ORDER and a
  /// multipart message interleaves text and attachments.
  static func empty(subject: NSAttributedString?) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("CKComposition")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("could not allocate a CKComposition")
    }
    guard
      let composition = try IMCoreRuntime.invoke(
        allocated, "initWithText:subject:",
        [NSAttributedString(string: ""), subject ?? NSNull()]
      )
    else {
      throw PrivateAPIErrorShim.rejected("CKComposition would not initialise")
    }
    return composition
  }

  /// Puts the file where the transfer says it lives, then tells the daemon about it.
  ///
  /// MEASURED on macOS 26. `mediaObjectWithFileURL:filename:transcoderUserInfo:` allocates
  /// a transfer and computes a `localPath` under Messages' own container tmp, but it does
  /// **not** copy the bytes there: the transfer reports `existsAtLocalPath = 0`,
  /// `totalBytes = 0`, `isFileURLFinalized = 0`. Messages' own UI reaches that copy through
  /// its transcode/preview pipeline, which a headless caller never drives. A message sent
  /// in that state carries a valid transfer GUID with nothing behind it, so imagent writes
  /// no attachment row and reports no error: the exact silent no-op this path produced.
  ///
  /// This is the ChatKit counterpart of IMCore's `_persistentPathForTransfer:` copy. That
  /// one is unusable here because its destination is `~/Library/Messages/Attachments`,
  /// outside Messages' sandbox: copying there fails with `NSCocoaErrorDomain 513`. This
  /// destination is inside the container we are running in, so the write is permitted.
  static func stageBytes(for media: AnyObject, from source: String) throws {
    guard let guid = try? IMCoreRuntime.string(media, "transferGUID") else {
      throw PrivateAPIErrorShim.rejected("the media object has no transfer GUID")
    }
    let center = try IMFileTransfers.center()
    guard let transfer = try IMCoreRuntime.send(center, "transferForGUID:", guid),
      let destination = try? IMCoreRuntime.string(transfer, "localPath"),
      !destination.isEmpty
    else {
      throw PrivateAPIErrorShim.rejected("transfer \(guid) has no local path")
    }

    let manager = FileManager.default
    if !manager.fileExists(atPath: destination) {
      try manager.createDirectory(
        at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try manager.copyItem(atPath: source, toPath: destination)
    }

    // Only now is there anything for the daemon to pick up.
    try IMCoreRuntime.invoke(center, "registerTransferWithDaemon:", [guid])
  }

  /// Appends a file. ChatKit handles the transfer registration itself.
  static func appendingMedia(_ composition: AnyObject, path: String) throws -> AnyObject {
    guard FileManager.default.fileExists(atPath: path) else {
      throw PrivateAPIErrorShim.rejected("no file at \(path)")
    }
    let manager = try IMCoreRuntime.sharedInstance(ofClass: "CKMediaObjectManager")
    guard
      let media = try IMCoreRuntime.invoke(
        manager, "mediaObjectWithFileURL:filename:transcoderUserInfo:",
        [URL(fileURLWithPath: path) as NSURL, NSNull(), NSNull()]
      )
    else {
      throw PrivateAPIErrorShim.rejected("ChatKit would not accept \(path) as media")
    }
    try stageBytes(for: media, from: path)
    guard
      let appended = try IMCoreRuntime.invoke(
        composition, "compositionByAppendingMediaObject:", [media]
      )
    else {
      throw PrivateAPIErrorShim.rejected("could not append the attachment")
    }
    return appended
  }

  /// Appends text, carrying a confirmed mention when there is one and any inline styles
  /// or effects the part asked for (`TextFormattingAttributes`).
  static func appendingText(
    _ composition: AnyObject, text: String, mention: String?,
    formatting: [FormattedRange] = []
  ) throws -> AnyObject {
    let run = NSMutableAttributedString(string: text)
    if let mention, !mention.isEmpty {
      run.addAttributes(
        [.init("__kIMMentionConfirmedMention"): mention],
        range: NSRange(location: 0, length: run.length)
      )
    }
    TextFormattingAttributes.apply(formatting, to: run)
    guard
      let appended = try IMCoreRuntime.invoke(
        composition, "compositionByAppendingText:", [run]
      )
    else {
      throw PrivateAPIErrorShim.rejected("could not append text to the composition")
    }
    return appended
  }

  /// Attaches a Send Later date, which is what makes the message scheduled.
  ///
  /// MEASURED, after the obvious approach failed: building an `IMMessage` through the
  /// initializer that takes `scheduleType:scheduleState:` and sending it with
  /// `-[IMChat sendMessage:]` sends it IMMEDIATELY: the row lands with
  /// `schedule_type = 0`, `is_delivered = 1` and a delivery time of now. Whatever files a
  /// message as scheduled is not those two words on the message.
  ///
  /// This is Messages' own route instead. `-[CKComposition(IMSuperFormat)
  /// messageWithGUID:superFormatText:…]` (disassembled on 26.5.2) asks the composition for
  /// its `sendLaterPluginInfo`; when there is one it passes that info's `selectedDate` as
  /// the message's `time:` along with `scheduleType 2` / `scheduleState 1`, and when there
  /// is not it passes `[NSDate date]` and 0 / 0. So the date goes on the COMPOSITION, and
  /// `messagesFromComposition:` builds a scheduled message from it.
  static func setSendLater(_ composition: AnyObject, _ date: Date?) throws {
    guard let date else { return }
    let type: AnyClass = try IMCoreRuntime.requireClass("CKSendLaterPluginInfo")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue(),
      let info = try IMCoreRuntime.invoke(
        allocated, "initWithSelectedDate:", [date as NSDate])
    else {
      throw PrivateAPIErrorShim.rejected("could not build the Send Later info")
    }
    guard
      IMCoreRuntime.responds(composition, to: NSSelectorFromString("setSendLaterPluginInfo:"))
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "scheduled send", requires: "CKComposition.setSendLaterPluginInfo:"
      )
    }
    try IMCoreRuntime.invoke(composition, "setSendLaterPluginInfo:", [info])
  }

  /// An audio composition, which ChatKit builds differently.
  ///
  /// A voice note assembled as an ordinary attachment arrives as a playable file rather
  /// than as a waveform, so the dedicated constructor is not interchangeable.
  static func audio(path: String) throws -> AnyObject {
    let manager = try IMCoreRuntime.sharedInstance(ofClass: "CKMediaObjectManager")
    guard
      let media = try IMCoreRuntime.invoke(
        manager, "mediaObjectWithFileURL:filename:transcoderUserInfo:",
        [URL(fileURLWithPath: path) as NSURL, NSNull(), NSNull()]
      )
    else {
      throw PrivateAPIErrorShim.rejected("ChatKit would not accept \(path) as media")
    }
    let type: AnyClass = try IMCoreRuntime.requireClass("CKComposition")
    guard
      let composition = try IMCoreRuntime.invoke(
        type as AnyObject, "audioCompositionWithMediaObject:", [media]
      )
    else {
      throw PrivateAPIErrorShim.rejected("could not build an audio composition")
    }
    return composition
  }

  /// Lets ChatKit finish preparing a media object before the message is sent.
  ///
  /// `CKMediaObjectManager` copies the file into Messages' container and links it on its
  /// own schedule, and the media reports `isFileURLFinalized:0 isFileDataReady:0` until it
  /// has. A message sent before that names a transfer with no bytes behind it, and the
  /// attachment is silently dropped; measured: the message arrives, `cache_has_attachments`
  /// stays 0, and no error is reported anywhere.
  ///
  /// **This is not sufficient on its own.** Measured with a 250ms settle in place, the
  /// message still arrives with `cache_has_attachments = 0` and no attachment row: even
  /// though the composition demonstrably carries the media and the built `IMMessage`
  /// carries its transfer GUID. So the loss is somewhere in `sendMessage:newComposition:`,
  /// not in how the composition is assembled. Kept because the unfinalized state is real
  /// and a send that races it cannot be correct either way; removing it would only hide
  /// one of the two problems.
  static func settle() async throws {
    try? await Task.sleep(for: .milliseconds(250))
  }

  /// A composition holding just this text. What an edit replaces a part with.
  static func withText(_ text: String) throws -> AnyObject {
    try appendingText(try empty(subject: nil), text: text, mention: nil)
  }

  static func setEffect(_ composition: AnyObject, _ effectID: String?) {
    guard let effectID, !effectID.isEmpty else { return }
    _ = try? IMCoreRuntime.invoke(composition, "setExpressiveSendStyleID:", [effectID])
  }
}
