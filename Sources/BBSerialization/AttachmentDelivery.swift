//  AttachmentDelivery
//  What a client receives for an attachment: decided once, said twice.
//
//  `GET /attachment/:guid/download` converts what most clients cannot open. HEIC and CAF are
//  what iMessage stores, and an Android client asking for a photo would otherwise get bytes it
//  cannot render. The reference converts while serializing and reports the converted type and
//  name as the attachment's `mimeType` and `transferName`, so a client is told JPEG and handed
//  JPEG. Clients branch on that string: one that reads `image/hei…` runs its own HEIC decoder
//  on the file it is given, and a JPEG under that name fails it. The metadata and the bytes have
//  to agree, and two code paths agree only by asking one function.
//
//  This is that function. The serializer asks it what to SAY, the conversion asks it what to
//  DO, and both are fed by `AttachmentMetadataReader`, which reads the facts off the header
//  once per attachment and caches them.
//
//  The decision is made from what is IN the file, never from what the row calls it.
//  `image/heic` is a photo and also a sticker, and `image/heic-sequence` is an animated
//  sticker. JPEG has no alpha, so a sticker written to JPEG sits on a black square; ImageIO
//  decodes frame 0 of a sequence without complaint, so a sequence written to a still is its
//  first frame with no error anywhere. A source with frames becomes an animated GIF, a source
//  with alpha a PNG, and a photo a JPEG. JPEG is the right answer for a photo on size, encode
//  time and the clients' decode path alike; PNG buys only alpha, and a camera photo has none.
//  The measurements are in `.claude/docs/decisions.md`.

import Foundation
import UniformTypeIdentifiers

public struct AttachmentDelivery: Sendable, Equatable {

  /// The four things a converted attachment can be.
  public enum Format: String, Sendable, Equatable, CaseIterable {
    case jpeg
    case png
    case gif
    case m4a

    public var mimeType: String {
      switch self {
      case .jpeg: "image/jpeg"
      case .png: "image/png"
      case .gif: "image/gif"
      case .m4a: "audio/x-m4a"
      }
    }

    /// Appended to the stored name AFTER its own extension: `IMG_0001.heic.jpeg`. That is the
    /// reference's spelling, which the clients and `LivePhotoSidecar` recognise: the transfer
    /// name, or the GUID when there is none, plus the new extension unless it already ends in
    /// it. `jpeg` rather than `jpg` for the same reason.
    public var fileExtension: String { rawValue }

    /// The name the serializer reports and the download sends for a converted file.
    public func transferName(for original: String?, guid: String) -> String {
      let base = (original?.isEmpty == false) ? original! : guid
      return base.lowercased().hasSuffix("." + fileExtension) ? base : base + "." + fileExtension
    }
  }

  public let format: Format

  public init(format: Format) {
    self.format = format
  }

  public var mimeType: String { format.mimeType }

  public func transferName(for original: String?, guid: String) -> String {
    format.transferName(for: original, guid: guid)
  }

  // MARK: - The decision

  /// Types clients open already. Anything else that is an image is converted.
  public static let widelySupportedImageTypes: Set<String> = [
    "image/jpeg", "image/jpg", "image/png", "image/gif", "image/webp",
  ]

  public static let widelySupportedAudioTypes: Set<String> = [
    "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/aac", "audio/wav",
  ]

  /// Sequence containers whose frames are an animation rather than pages. `public.heics` is
  /// what Messages writes for an animated sticker; the other three are what a client could
  /// send. `UTType` has no static for HEICS, so the identifier is spelled out.
  public static let animatedContainers: Set<String> = [
    "public.heics", UTType.gif.identifier, UTType.webP.identifier, UTType.png.identifier,
  ]

  /// What the download will serve for this attachment, or nil for the file as stored.
  ///
  /// - Parameters:
  ///   - kind: image, audio or video, from `AttachmentMetadataReader.kind(of:)`; nil for a
  ///     document, which is never converted.
  ///   - mimeType: the row's, or one derived from the extension when the row has none.
  ///   - traits: what the header says, for an image that is not widely supported. Nil means
  ///     ImageIO could not open the file, and the answer is the original: the conversion would
  ///     fail and serve it anyway, which is also what the reference reports for a file its
  ///     conversion refuses.
  public static func plan(
    kind: AttachmentMetadata.Kind?,
    mimeType: String?,
    traits: ImageTraits?
  ) -> AttachmentDelivery? {
    switch kind {
    case .image:
      if let mimeType, widelySupportedImageTypes.contains(mimeType) { return nil }
      guard let traits else { return nil }
      return AttachmentDelivery(format: format(for: traits))
    case .audio:
      if let mimeType, widelySupportedAudioTypes.contains(mimeType) { return nil }
      return AttachmentDelivery(format: .m4a)
    case .video, nil:
      return nil
    }
  }

  /// Animation first, because an animated sticker has alpha too and a PNG of it would be a
  /// still; then alpha, because JPEG has none; then JPEG.
  public static func format(for traits: ImageTraits) -> Format {
    if traits.isAnimated { return .gif }
    if traits.hasAlpha { return .png }
    return .jpeg
  }

  /// The format for a `width`, `height` or `quality` request on an image that needed no
  /// conversion.
  ///
  /// The source's own format where ImageIO can write it, so the `mimeType` the client was told
  /// still describes what a resize returns. The reference writes every resize as PNG and says
  /// so only in the Content-Type; a client that asked for a smaller JPEG and keeps it under the
  /// name it was given is better served by a JPEG. WebP has no ImageIO encoder, so it is
  /// decided like a conversion.
  public static func resizeFormat(mimeType: String, traits: ImageTraits?) -> Format {
    switch mimeType {
    case "image/jpeg", "image/jpg": .jpeg
    case "image/png": .png
    default: traits.map(format(for:)) ?? .jpeg
    }
  }
}
