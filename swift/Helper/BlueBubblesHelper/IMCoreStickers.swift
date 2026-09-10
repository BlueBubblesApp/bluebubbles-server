//  IMCoreStickers
//  Stickers: placing one on a message, and reading the user's sticker store.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ImageIO
import ObjectiveC.runtime

// MARK: - Stickers

/// The sticker model and the ChatKit objects that turn one into a sendable composition.
///
/// Every selector here was read out of Messages' own drag-and-drop send on macOS 26.5.2
/// (`-[CKChatController sendSticker:withDragTarget:draggedSticker:]` and what it calls),
/// so the objects are built the way Messages builds them rather than assembled from the
/// attachment path with a flag flipped. The difference is visible on every other device:
/// a plain attachment sent with `associatedMessageType` 1000 has no `stickerUserInfo`,
/// no `isSticker` on its transfer and no attribution, and iOS draws it as a broken
/// attachment rather than a sticker.
///
/// The chain, in the order Messages runs it:
///
///     IMSticker  ──▶  +[IMSticker userInfoDictionaryWithLayoutIntent:…]   (the geometry)
///                ──▶  -[CKMediaObjectManager mediaObjectWithSticker:stickerUserInfo:]
///                        copies the file into ChatKit's staging area, creates the
///                        transfer through -[CKIMFileTransfer initWithStickerFileURL:…]
///                        (isSticker = YES, stickerUserInfo, attributionInfo), registers
///                        it with IMFileTransferCenter
///                ──▶  +[CKComposition stickerCompositionWithMediaObjects:]
///                ──▶  IMMessage (IMMessageBuilder.sticker)
///                ──▶  -[CKConversation sendMessage:newComposition:NO]
enum IMStickers {

  /// The pack every user-made sticker on this Mac belongs to.
  ///
  /// Read from the `pid` of received stickers and from the attribution row Messages writes
  /// for its own: user-generated stickers (the ones lifted out of a photo) are attributed
  /// to the built-in Stickers extension, and this is its plugin identifier. It doubles as
  /// the balloon bundle id, which is what `mediaObjectWithSticker:` looks up to attach the
  /// "Stickers" attribution that the sticker detail sheet shows on the receiving device.
  static let userGeneratedPackID =
    "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:"
    + "com.apple.Stickers.UserGenerated.MessagesExtension"

  /// An `IMSticker` for a file on disk.
  ///
  /// ObjC: `-[IMSticker initWithStickerID:stickerPackID:fileURL:accessibilityLabel:
  /// accessibilityName:moodCategory:stickerName:]`. The sticker id is a fresh UUID with
  /// the file's extension, which is the shape Messages uses for its own (`sid` on the
  /// attachment row is `<UUID>.heic`); it identifies the sticker in recents and in the
  /// dedup of the receiving device's sticker drawer, so it must not repeat across sends.
  ///
  /// TWO GENERATIONS. `accessibilityName:` was inserted **in the middle** of the keyword
  /// list in macOS 15, right after `accessibilityLabel:`:
  ///
  ///   15, 26    …fileURL:accessibilityLabel:accessibilityName:moodCategory:stickerName:
  ///   14        …fileURL:accessibilityLabel:moodCategory:stickerName:
  ///
  /// so the older form takes one fewer argument, not the same arguments under another name.
  /// Calling only the newer meant stickers did not send at all on Sonoma
  /// (`docs/SONOMA_COMPATIBILITY.md` §3). Every argument after the URL is `NSNull` here:
  /// Messages leaves them nil for a user-generated sticker, which is why dropping one
  /// changes nothing about the sticker that gets built.
  static func sticker(path: String) throws -> AnyObject {
    guard FileManager.default.fileExists(atPath: path) else {
      throw PrivateAPIErrorShim.rejected("no file at \(path)")
    }
    let type: AnyClass = try IMCoreRuntime.requireClass("IMSticker")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("could not allocate an IMSticker")
    }
    let url = URL(fileURLWithPath: path)
    let extensionPart = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
    let stickerID = UUID().uuidString + extensionPart

    let leading: [Any] = [stickerID, userGeneratedPackID, url as NSURL]
    let candidates: [(String, [Any])] = [
      (
        "initWithStickerID:stickerPackID:fileURL:accessibilityLabel:accessibilityName:"
          + "moodCategory:stickerName:",
        leading + [NSNull(), NSNull(), NSNull(), NSNull()]
      ),
      (
        "initWithStickerID:stickerPackID:fileURL:accessibilityLabel:moodCategory:"
          + "stickerName:",
        leading + [NSNull(), NSNull(), NSNull()]
      ),
    ]
    guard
      let (selector, arguments) = candidates.first(where: {
        IMCoreRuntime.responds(allocated, to: NSSelectorFromString($0.0))
      })
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "sendSticker", requires: "an IMSticker initWithStickerID: initializer")
    }
    guard
      let sticker = try IMCoreRuntime.invoke(
        allocated,
        selector,
        arguments
      )
    else {
      throw PrivateAPIErrorShim.rejected("IMSticker would not initialise for \(path)")
    }
    // What `mediaObjectWithSticker:` looks up for attribution. Set separately because the
    // initializer has no parameter for it.
    if IMCoreRuntime.responds(sticker, to: NSSelectorFromString("setBallonBundleID:")) {
      _ = try? IMCoreRuntime.invoke(sticker, "setBallonBundleID:", [userGeneratedPackID])
    }
    return sticker
  }

  /// The `stickerUserInfo` dictionary: where the sticker sits on its parent.
  ///
  /// ObjC: `+[IMSticker userInfoDictionaryWithLayoutIntent:parentPreviewWidth:xScalar:
  /// yScalar:scale:rotation:initialFrameIndex:stickerPositionVersion:externalURI:]`,
  /// which writes the `sli`/`spw`/`sxs`/`sys`/`ssa`/`sro`/`safi`/`spv`/`suri` keys.
  /// Messages passes layout intent 0, frame index 0 and position version 0 for a dropped
  /// sticker, and so does this. The external URI is `[sticker getSafeExternalURI]` there:
  /// a string, EMPTY for a sticker with no App Store origin, and it must be a string: the
  /// builder puts all ten values in a dictionary literal, and nil raises
  /// `attempt to insert nil object from objects[9]` (measured).
  ///
  /// TWO GENERATIONS, and unlike the initializer above the difference is at the END:
  /// `externalURI:` was appended in macOS 15. Sonoma's longest form stops at
  /// `stickerPositionVersion:`, so it takes eight values rather than nine and the
  /// dictionary it builds simply has no `suri` key, which is what a Sonoma sticker
  /// legitimately looks like, since `externalURI` is empty for a user-generated one
  /// anyway. `docs/SONOMA_COMPATIBILITY.md` §3.
  static func userInfo(placement: StickerPlacement) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("IMSticker")
    let geometry: [Any] = [
      UInt(0), placement.parentPreviewWidth, placement.xScalar, placement.yScalar,
      placement.scale, placement.rotation, UInt(0), UInt(0),
    ]
    let candidates: [(String, [Any])] = [
      (
        "userInfoDictionaryWithLayoutIntent:parentPreviewWidth:xScalar:yScalar:scale:"
          + "rotation:initialFrameIndex:stickerPositionVersion:externalURI:",
        geometry + [""]
      ),
      (
        "userInfoDictionaryWithLayoutIntent:parentPreviewWidth:xScalar:yScalar:scale:"
          + "rotation:initialFrameIndex:stickerPositionVersion:",
        geometry
      ),
    ]
    guard
      let (selector, arguments) = candidates.first(where: {
        (type as AnyObject).responds(to: NSSelectorFromString($0.0))
      })
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "sendSticker",
        requires: "an IMSticker userInfoDictionaryWithLayoutIntent: class method")
    }
    guard
      let dictionary = try IMCoreRuntime.invoke(type as AnyObject, selector, arguments)
    else {
      throw PrivateAPIErrorShim.rejected("IMSticker produced no sticker user info")
    }
    return dictionary
  }

  /// The ChatKit media object wrapping a sticker transfer.
  ///
  /// ObjC: `-[CKMediaObjectManager mediaObjectWithSticker:stickerUserInfo:]`. This is the
  /// step that does the work the attachment path does by hand elsewhere: it copies the
  /// file into ChatKit's own staging directory, creates the transfer through
  /// `initWithStickerFileURL:…` (which is where `isSticker`, `stickerUserInfo` and the
  /// attribution land on the `IMFileTransfer`) and registers it with the transfer center.
  /// It logs and returns nil when any of that fails, so nil here is reported rather than
  /// sent.
  static func mediaObject(sticker: AnyObject, userInfo: AnyObject) throws -> AnyObject {
    let manager = try IMCoreRuntime.sharedInstance(ofClass: "CKMediaObjectManager")
    guard
      let media = try IMCoreRuntime.invoke(
        manager, "mediaObjectWithSticker:stickerUserInfo:", [sticker, userInfo]
      )
    else {
      throw PrivateAPIErrorShim.rejected(
        "ChatKit would not build a media object for the sticker: the file may not be an "
          + "image, or could not be copied into Messages' container"
      )
    }
    return media
  }

  /// ObjC: `+[CKComposition stickerCompositionWithMediaObjects:]`, which is
  /// `compositionWithMediaObjects:subject:nil` under a name that says what it is for.
  static func composition(media: AnyObject) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("CKComposition")
    guard
      let composition = try IMCoreRuntime.invoke(
        type as AnyObject, "stickerCompositionWithMediaObjects:", [[media]]
      )
    else {
      throw PrivateAPIErrorShim.rejected("could not build a sticker composition")
    }
    return composition
  }

  /// The message text a composition sends as: the attachment placeholder character
  /// carrying the transfer GUID as an attribute.
  ///
  /// ObjC: `-[CKComposition superFormatText:]`, called with a NULL out-pointer. Messages
  /// passes a real one to collect the transfer GUIDs; the GUID is read off the media
  /// object instead, because the invocation bridge only writes nil into pointer arguments
  /// (and rightly; see `BBSetArgument`). Same text either way.
  static func superFormatText(_ composition: AnyObject) throws -> NSAttributedString {
    guard
      let text = try IMCoreRuntime.invoke(composition, "superFormatText:", [NSNull()])
        as? NSAttributedString
    else {
      throw PrivateAPIErrorShim.rejected("the sticker composition produced no message text")
    }
    return text
  }

  /// The range of a message part within its message's text.
  ///
  /// ObjC: `-[IMMessagePartChatItem messagePartRange]`. A struct return, which is why the
  /// invocation bridge boxes those as `NSValue`.
  static func partRange(_ part: AnyObject) throws -> NSRange {
    guard let value = try IMCoreRuntime.invoke(part, "messagePartRange") as? NSValue else {
      throw PrivateAPIErrorShim.rejected("that message part reports no range")
    }
    return value.rangeValue
  }
}

// MARK: - The sticker store

/// Writing into this Mac's sticker store, which is what puts a sticker in the picker.
///
/// The store is `stickers.stickerdb` inside the `com.apple.stickersd.group` container, owned
/// by `stickersd`. READING it needs none of this: the server opens that SQLite file
/// directly, so listing stickers works on a Mac with no helper at all (see
/// `StickerLibrary`). Writing does: the container is entitled to the group, and Messages
/// holds that entitlement while this server does not.
///
/// The only write Messages exposes is a DONATION to recents:
///
///     -[_STKMessagesObjCStoreFacade
///         donateStickerToRecentsWithIdentifier:representations:stickerEffectEnum:
///         externalURI:name:accessibilityName:metadata:attributionInfo:error:]
///
/// which is what Messages itself calls after sending a sticker. There is no "add to the
/// saved library" call on the facade, and that asymmetry is real rather than an oversight
/// on our part: saved stickers are created by the Stickers extension lifting a subject out
/// of a photo, which is a UI flow, not an API. `docs/STICKER_LIBRARY.md` records the
/// measurements.
enum IMStickerStore {

  /// Stickers.framework is private and may not be loaded until the picker is first opened.
  private static let frameworkPath =
    "/System/Library/PrivateFrameworks/Stickers.framework/Stickers"

  private static func requireStickersClass(_ name: String) throws -> AnyClass {
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

  /// The role the store files a single-image sticker under.
  ///
  /// Messages writes TWO representations for a sticker it made itself (a `still` HEIC at
  /// full size and a `keyboard` PNG preview) and NO role at all (an empty string) for the
  /// emoji and Genmoji rows. A single uploaded image is the second shape, so the role is
  /// left empty rather than claimed to be a still of something with no keyboard preview.
  static let singleImageRole = ""

  /// One representation over an image's bytes.
  ///
  /// **`_STKStickerUIStickerRepresentation`, not `STKStickerRepresentation`**, and the
  /// difference is not cosmetic. `STKStickerRepresentation` is the archivable model, and its
  /// `-init` is a Swift **unimplemented initializer**: it loads the strings
  /// `"Stickers.Representation"` and `"init()"` and executes `brk #0x1`. Calling it does not
  /// fail, it TRAPS: measured, and it took Messages down with `EXC_BREAKPOINT` at
  /// `Stickers` + 0x7306c, which is that `brk` exactly.
  ///
  /// The type the donation actually wants was read out of the facade itself:
  /// `-donateStickerToRecentsWithIdentifier:…` calls `type metadata accessor for
  /// Stickers._STKStickerUIStickerRepresentation` at +76, before it touches anything else.
  /// That class has a real, complete initializer (`-initWithData:type:size:role:`) which
  /// is why nothing here needs setters.
  static func representation(data: Data, role: String = singleImageRole) throws -> AnyObject {
    let type: AnyClass = try requireStickersClass("_STKStickerUIStickerRepresentation")
    let (uti, size) = try Self.describe(data)
    guard
      let representation = try IMCoreRuntime.invoke(
        try allocate(type), "initWithData:type:size:role:",
        [data as NSData, uti, NSValue(size: size), role]
      )
    else {
      throw PrivateAPIErrorShim.rejected(
        "the sticker store would not accept that image as a representation")
    }
    return representation
  }

  /// The image's uniform type identifier and pixel size, read from the bytes.
  ///
  /// Read rather than taken from the filename: the store records a UTI per representation
  /// and a size it draws with, and a client that uploads a PNG named `.heic` should not end
  /// up with a row that lies about either. ImageIO is the same decoder Messages uses.
  private static func describe(_ data: Data) throws -> (uti: String, size: CGSize) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let uti = CGImageSourceGetType(source) as String?
    else {
      throw PrivateAPIErrorShim.rejected(
        "that file is not an image any installed decoder recognises")
    }
    let properties =
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
    let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
    guard width > 0, height > 0 else {
      throw PrivateAPIErrorShim.rejected("that image reports no dimensions")
    }
    return (uti, CGSize(width: width, height: height))
  }

  /// Attribution: who this sticker came from, shown on the sticker detail sheet.
  ///
  /// Attributed to the built-in Stickers extension, the same as `IMStickers` uses for a
  /// send, because that is what a sticker made on this Mac genuinely is as far as the
  /// receiving device can tell.
  static func attribution() throws -> AnyObject {
    let type: AnyClass = try requireStickersClass("_STKStickerAttributionInfo")
    guard
      let info = try IMCoreRuntime.invoke(
        try allocate(type), "initWithAdamID:bundleIdentifier:name:",
        [NSNull(), IMStickers.userGeneratedPackID, "Stickers"]
      )
    else {
      throw PrivateAPIErrorShim.rejected("_STKStickerAttributionInfo would not initialise")
    }
    return info
  }

  /// Donates a sticker to recents, and answers with the identifier the store filed it under.
  ///
  /// The identifier is minted here rather than by the store (the selector takes it) and
  /// the external URI is built in the store's own `sticker:///user/identifier/<UUID>` shape,
  /// which is what every user-generated row in `stickers.stickerdb` carries.
  static func donateToRecents(
    data: Data, name: String?, accessibilityName: String?
  ) throws -> (identifier: UUID, externalURI: String) {
    let type: AnyClass = try requireStickersClass("_STKMessagesObjCStoreFacade")
    guard let facade = try IMCoreRuntime.invoke(try allocate(type), "init") else {
      throw PrivateAPIErrorShim.rejected("_STKMessagesObjCStoreFacade would not initialise")
    }

    let identifier = UUID()
    let externalURI = "sticker:///user/identifier/\(identifier.uuidString)"
    let representation = try representation(data: data)

    // -1 is what every row Messages wrote for a plain sticker carries; 0 is what the two
    // rows with an effect carry. No effect is the honest value for an uploaded image.
    let noEffect = Int64(-1)
    let result = try IMCoreRuntime.invoke(
      facade,
      "donateStickerToRecentsWithIdentifier:representations:stickerEffectEnum:externalURI:"
        + "name:accessibilityName:metadata:attributionInfo:error:",
      [
        // A STRING, not an NSUUID. Measured: passing the UUID object raises
        // `-[__NSConcreteUUID length]: unrecognized selector`, so the facade takes the
        // uppercase dashed form the store's own `ZEXTERNALURI` rows use.
        identifier.uuidString, [representation], noEffect, externalURI,
        name ?? "", accessibilityName ?? "", NSNull(), try attribution(), NSNull(),
      ]
    )

    // The selector returns BOOL and reports why through its `error` out-parameter, which
    // the invocation bridge cannot fill in, so a false here is reported as a refusal
    // rather than dressed up with a reason we do not have.
    if let answered = result as? NSNumber, !answered.boolValue {
      throw PrivateAPIErrorShim.rejected(
        "the sticker store refused the donation: the image may not be a type Stickers "
          + "reads, or stickersd may not be running"
      )
    }
    return (identifier, externalURI)
  }
}
