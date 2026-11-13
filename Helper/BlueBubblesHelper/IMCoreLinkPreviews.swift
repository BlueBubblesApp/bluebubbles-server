//  IMCoreLinkPreviews
//  The link preview a `ddScan` send carries on releases whose scan does not fetch one.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import Foundation
import HelperShared

/// Fetches a link's preview and sends it the way Messages does, for Sonoma and Sequoia.
///
/// **Why only there.** On Tahoe and 27, `-[IMDDController scanMessage:…]` fetches the preview
/// itself: `-_processForRichLinksInAttributedString:plainText:didProcess:` is on `IMDDController`
/// in the 26.6.2 and 27.0.1 dumps, and a scanned send goes out as a
/// `com.apple.messages.URLBalloonProvider` balloon whose `payload_data` is a complete `RichLink`.
/// On 14.6.1 and 15.6.1 that selector is absent, and the same send goes out as a balloon whose
/// payload is `{richLinkIsPlaceholder: true}` with no metadata, which a recipient's iPhone shows
/// as "Tap to load preview". In Messages.app on those releases the fetch is done by the URL
/// balloon plugin's data source once the link reaches the compose field; a send through IMCore
/// never puts it there. The selector's presence decides, not the version number.
///
/// **What it builds is what 27 sends.** `LPMetadataProvider` fetches the metadata,
/// `LPMessagesPayload` flattens it into the payload and its images, and a ChatKit composition
/// carrying a `CKBrowserItemPayload` turns the images into plugin-payload transfers. Measured on
/// 27.0.1 against one link: the payload this produces and the one the scan produced were the
/// same size, with the same four attachment sizes.
///
/// **A preview never stops a message.** A fetch that fails or runs past its deadline, or a
/// composition ChatKit will not build, sends the message as the scan leaves it: the placeholder,
/// which is what happened before this existed. Only a message whose whole text is one http(s)
/// link takes this path; text around a link still goes through the scan.
enum IMLinkPreviews {

  /// A preview ready to send: its payload, and its images staged as files.
  struct Preview {
    let url: URL
    let payload: Data
    let attachments: [URL]
  }

  /// The selector that makes the scan fetch the preview on Tahoe and 27.
  static let scanFetchSelector = "_processForRichLinksInAttributedString:plainText:didProcess:"

  static let balloonBundleID = "com.apple.messages.URLBalloonProvider"

  /// How long a send waits for the preview before going out without it. Messages.app shows the
  /// preview as it loads and sends whatever it has; a send here has no field to show it in, so
  /// it waits, but not for long enough to make a send look stuck.
  static let fetchTimeout: Duration = .seconds(8)

  /// Whether this release's scan fetches the preview itself. Answers yes when there is no
  /// scanner at all, because then the scan sends the message untouched and there is no
  /// placeholder to replace.
  static var scanFetchesPreview: Bool {
    guard let controller = try? IMCoreRuntime.sharedInstance(ofClass: "IMDDController") else {
      return true
    }
    return IMCoreRuntime.responds(controller, to: scanFetchSelector)
  }

  /// The link, when the trimmed text is exactly one http(s) link and nothing else.
  static func soleLink(in text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return nil }
    let whole = NSRange(trimmed.startIndex..., in: trimmed)
    let matches = detector.matches(in: trimmed, options: [], range: whole)
    guard matches.count == 1, let match = matches.first, match.range == whole,
      let url = match.url, let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return nil }
    return url
  }

  /// Fetches and flattens the preview for `url`, or nil when there is none to send.
  ///
  /// Called BEFORE the block that builds and sends the message, never inside it: the wait
  /// suspends, and a suspension between building a composition and sending it drains the
  /// autorelease pool holding its transfers (see `sendAttachment`).
  @MainActor
  static func fetch(_ url: URL) async -> Preview? {
    guard let metadata = await metadata(for: url) else { return nil }
    return try? flatten(metadata, url: url)
  }

  /// The messages ChatKit builds for `preview`, ready to send in `conversation`.
  static func messages(
    for preview: Preview, effectID: String?, in conversation: CKConversation
  ) throws -> [AnyObject] {
    // ChatKit's subclass, as `CKCompositions.appBalloon` explains: the composition calls
    // `-__ck_urlFromTextBodyForRichLink` on it, which a bare `IMPluginPayload` lacks.
    let pluginPayload = try IMCoreRuntime.create(
      try IMCoreRuntime.requireClass("CKBrowserItemPayload"), "init")
    try IMCoreRuntime.invoke(pluginPayload, "setPluginBundleID:", [balloonBundleID])
    try IMCoreRuntime.invoke(pluginPayload, "setUrl:", [preview.url as NSURL])
    try IMCoreRuntime.invoke(
      pluginPayload, "setText:", [NSAttributedString(string: preview.url.absoluteString)])
    try IMCoreRuntime.invoke(pluginPayload, "setData:", [preview.payload as NSData])
    try IMCoreRuntime.invoke(
      pluginPayload, "setAttachments:", [preview.attachments.map { $0 as NSURL } as NSArray])

    let type: AnyClass = try IMCoreRuntime.requireClass("CKComposition")
    let builder = try IMCoreRuntime.requireResponding(
      type as AnyObject, among: CKCompositions.shelfCompositionBuilders)
    guard let composition = try IMCoreRuntime.invoke(type as AnyObject, builder, [pluginPayload])
    else {
      throw PrivateAPIErrorShim.rejected("ChatKit would not build a composition for the link")
    }
    CKCompositions.setEffect(composition, effectID)
    guard conversation.canSend(composition) else {
      throw PrivateAPIErrorShim.rejected("ChatKit will not send this link preview")
    }
    let messages = try conversation.messages(from: composition)
    guard !messages.isEmpty else {
      throw PrivateAPIErrorShim.rejected("ChatKit produced no message for the link")
    }
    return messages
  }

  // MARK: - Fetching

  /// Holds the metadata across the completion's queue. Written once, through `ResumeOnce`.
  private final class Fetched: @unchecked Sendable {
    let metadata: AnyObject
    init(_ metadata: AnyObject) { self.metadata = metadata }
  }

  @MainActor
  private static func metadata(for url: URL) async -> AnyObject? {
    guard let providerClass = IMCoreRuntime.lookUpClass("LPMetadataProvider"),
      let provider = try? IMCoreRuntime.create(providerClass, "init")
    else { return nil }
    // The provider's own deadline as well as ours, so a fetch we stop waiting for also stops.
    let seconds = Double(fetchTimeout.components.seconds)
    _ = try? IMCoreRuntime.invoke(provider, "setTimeout:", [NSNumber(value: seconds)])

    let once = ResumeOnce<Fetched?>()
    // Two objects, as `LPMetadataProvider`'s public header declares the handler:
    // `(LPLinkMetadata * _Nullable, NSError * _Nullable)`. Called on a background queue.
    let completion: @convention(block) (AnyObject?, AnyObject?) -> Void = { metadata, _ in
      once.finish(metadata.map(Fetched.init))
    }
    do {
      try IMCoreRuntime.invoke(
        provider, "startFetchingMetadataForURL:completionHandler:",
        [url as NSURL, unsafeBitCast(completion, to: AnyObject.self)])
    } catch {
      return nil
    }
    let fetched = await once.wait(timeout: fetchTimeout, onTimeout: nil)
    if fetched == nil { _ = try? IMCoreRuntime.invoke(provider, "cancel") }
    return withExtendedLifetime(provider) { fetched?.metadata }
  }

  // MARK: - Flattening

  /// The `RichLink` payload and its images, the images written where ChatKit can read them.
  ///
  /// The images come back through an `id *`; passing nil instead makes LinkPresentation inline
  /// them into the payload (312 KB rather than 3 KB, measured), which is not what Messages
  /// sends. Each is written under this process's temporary directory, inside Messages'
  /// container, named the way Messages names a plugin-payload attachment.
  private static func flatten(_ metadata: AnyObject, url: URL) throws -> Preview {
    let payload = try IMCoreRuntime.create(
      try IMCoreRuntime.requireClass("LPMessagesPayload"), "init")
    try IMCoreRuntime.invoke(payload, "setMetadata:", [metadata])
    let (data, received) = try IMCoreRuntime.invoke(
      payload, "dataRepresentationWithOutOfLineAttachments:", [], receivingObjectAt: 0)
    guard let data = data as? Data else {
      throw PrivateAPIErrorShim.rejected("LinkPresentation produced no payload for the link")
    }
    let images = (received as? [Any] ?? []).compactMap { $0 as? Data }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("link-previews", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let files = try images.map { image -> URL in
      let file = directory.appendingPathComponent("\(UUID().uuidString).pluginPayloadAttachment")
      try image.write(to: file)
      return file
    }
    return Preview(url: url, payload: data, attachments: files)
  }
}
