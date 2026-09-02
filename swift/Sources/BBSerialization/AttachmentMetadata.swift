//  AttachmentMetadata
//  An attachment's dimensions and duration, read from the file on disk.
//
//  `height`, `width` and `metadata` were a placeholder: `AttachmentSerializer` took a
//  `dimensions` parameter that NEITHER call site passed, so every attachment on every route
//  answered `height: 0, width: 0, metadata: {}`. The key set was right, which is why the
//  parity replay could not see it — it compares shape, and the shape was correct. It was
//  found by sending a real 16×16 PNG and reading back zeroes.
//
//  What a client loses without it is layout: a gallery sizes its cells from `height`/`width`
//  before the bytes arrive, and zero means it cannot.
//
//  ## Where the numbers come from, and how that differs from the reference
//
//  The reference shells out to `mdls` and maps forty-odd `kMDItem…` keys into friendly names.
//  This reads the file directly — ImageIO for images, AVFoundation for audio and video — and
//  emits the SAME key names for the fields that carry meaning. Two deliberate consequences:
//
//  - **It is a subset.** The reference's EXIF tail (`aperture`, `focalLength`, `deviceMake`,
//    `colorSpace`, …) comes from Spotlight and is not reproduced. Those keys are absent here
//    rather than null, which is what the reference does for a file Spotlight has not indexed.
//    Both recorded fixtures carry exactly the three keys below.
//  - **It does not depend on Spotlight.** `mdls` answers nothing for a file in a container
//    Spotlight has not reached, and returns stale values for one that changed. Reading the
//    header is both faster and correct.
//
//  The key NAMES differ by media type in the reference and are reproduced exactly: an image's
//  file size is `size`, an audio or video file's is `bytes`.

import AVFoundation
import BBIMessage
import Foundation
import ImageIO

public struct AttachmentMetadata: Sendable, Equatable {
  public var height: Int?
  public var width: Int?
  /// File size. Serialised as `size` for an image and `bytes` for audio or video, matching
  /// the reference's per-type key maps.
  public var byteSize: Int?
  public var duration: Double?

  public enum Kind: Sendable, Equatable {
    case image
    case audio
    case video
  }
  public var kind: Kind

  public init(
    kind: Kind, height: Int? = nil, width: Int? = nil, byteSize: Int? = nil,
    duration: Double? = nil
  ) {
    self.kind = kind
    self.height = height
    self.width = width
    self.byteSize = byteSize
    self.duration = duration
  }

  /// Nothing was readable. Distinct from "not a medium we read", which produces no metadata
  /// object at all — see `AttachmentSerializer`.
  public var isEmpty: Bool {
    height == nil && width == nil && byteSize == nil && duration == nil
  }

  /// The wire object. Absent keys rather than nulls: the reference builds this from whatever
  /// Spotlight returned and omits the rest.
  public func json() -> JSONValue {
    var object = JSONObjectBuilder()
    switch kind {
    case .image:
      if let byteSize { object.set("size", .int(byteSize)) }
    case .audio, .video:
      if let byteSize { object.set("bytes", .int(byteSize)) }
    }
    if let height { object.set("height", .int(height)) }
    if let width { object.set("width", .int(width)) }
    if let duration { object.set("duration", .double(duration)) }
    return object.build()
  }
}

/// Reads attachment metadata off disk, once per attachment.
///
/// An actor with a cache, because `loadMetadata` is ON by default in the reference's
/// attachment config and a message page can carry hundreds of attachments — an uncached
/// implementation opens a file per row, per request, for an answer that cannot change once
/// the transfer has finished. `Query.withAttachmentMetadata` gates the cost at the route
/// level; this gates it again across requests.
///
/// A file that has NOT finished transferring is not cached: `transferState` moves and the
/// dimensions arrive with it, so caching an early read would pin the zeroes forever.
public actor AttachmentMetadataReader {

  /// Attachment GUID to what was read.
  private var cache: [String: AttachmentMetadata] = [:]

  public init() {}

  /// Nil when the attachment is not a medium this reads, or the file is not on disk.
  ///
  /// Both cases are meaningful and different, and the serializer tells them apart: a missing
  /// file answers `metadata: null`, a PDF answers no `metadata` key at all — which is what
  /// the reference does, because its `getAttachmentMetadata` returns `undefined` for a mime
  /// type it does not handle and `JSON.stringify` drops the key.
  public func metadata(for attachment: AttachmentRow) async -> AttachmentMetadata? {
    if let cached = cache[attachment.guid] { return cached }
    guard let kind = Self.kind(of: attachment) else { return nil }
    guard let path = attachment.resolvedPath,
      FileManager.default.fileExists(atPath: path)
    else { return nil }

    var metadata = AttachmentMetadata(kind: kind)
    metadata.byteSize =
      (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil

    let url = URL(fileURLWithPath: path)
    switch kind {
    case .image:
      Self.readImage(at: url, into: &metadata)
    case .audio, .video:
      await Self.readAsset(at: url, into: &metadata)
    }

    // Only once it has settled. `transferState` 5 is a finished transfer; anything else is
    // still moving, and the dimensions move with it.
    if attachment.transferState == Self.transferComplete {
      cache[attachment.guid] = metadata
    }
    return metadata
  }

  /// Finished. The same value the reference reports and clients branch on.
  static let transferComplete = 5

  /// Which reader applies, from the mime type — falling back to the UTI for Apple's audio
  /// format, which is what a voice note is stored as and which carries no mime type.
  static func kind(of attachment: AttachmentRow) -> AttachmentMetadata.Kind? {
    if attachment.uti == "com.apple.coreaudio-format" { return .audio }
    guard let mime = attachment.mimeType else { return nil }
    if mime.hasPrefix("image") { return .image }
    if mime.hasPrefix("audio") { return .audio }
    if mime.hasPrefix("video") { return .video }
    return nil
  }

  /// The image header only. `CGImageSourceCopyPropertiesAtIndex` does not decode pixels, so
  /// this costs a read of the first few hundred bytes rather than of the whole file.
  private static func readImage(at url: URL, into metadata: inout AttachmentMetadata) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any]
    else { return }
    metadata.height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    metadata.width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
  }

  private static func readAsset(at url: URL, into metadata: inout AttachmentMetadata) async {
    let asset = AVURLAsset(url: url)
    if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite {
      metadata.duration = seconds
    }
    guard
      let track = try? await asset.loadTracks(withMediaType: .video).first,
      let size = try? await track.load(.naturalSize)
    else { return }
    // The presented size, not the stored one: a video recorded in portrait is stored
    // landscape with a rotation transform, and a client laying out the un-transformed
    // dimensions renders it sideways.
    let transformed = size.applying((try? await track.load(.preferredTransform)) ?? .identity)
    metadata.height = Int(abs(transformed.height).rounded())
    metadata.width = Int(abs(transformed.width).rounded())
  }
}
