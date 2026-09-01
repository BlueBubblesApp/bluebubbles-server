//  MediaConversion
//  Image and audio conversion without subprocesses.
//
//  Replaces `sips --setProperty format jpeg`, `afconvert` for caf↔mp3, and `mdls` for file
//  metadata. Each of those spawns a process, writes through a temporary file, and reports
//  failure as unparsed text on stderr.
//
//  There is a second reason beyond tidiness: these run on the attachment path, which is the
//  hot path for a chat full of photos. A fork+exec per attachment is a real cost, and doing
//  it in-process removes both that and the temporary files it needed.
//
//  See `.claude/docs/performance.md`.

import AVFoundation
import BBCore
import CoreServices
import Foundation
import ImageIO
import Logging
import UniformTypeIdentifiers

public enum MediaConversionError: BBError, Equatable {
  case unreadableSource(path: String)
  case unsupportedFormat(String)
  case conversionFailed(reason: String)
}

// MARK: - Images

public enum ImageConverter {

  /// Converts an image, optionally downscaling.
  ///
  /// - Parameter maximumDimension: Longest edge. Preserves aspect ratio. Applied via
  ///   ImageIO's thumbnail path, which decodes at the target size rather than decoding the
  ///   full image and then shrinking it — the difference is large for a modern phone photo.
  public static func convert(
    source: String,
    destination: String,
    to type: UTType = .jpeg,
    quality: Double = 0.85,
    maximumDimension: Int? = nil
  ) throws {
    guard
      let imageSource = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: source) as CFURL, nil
      )
    else {
      throw MediaConversionError.unreadableSource(path: source)
    }

    let image: CGImage?
    if let maximumDimension {
      image = CGImageSourceCreateThumbnailAtIndex(
        imageSource, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
          // Without this an image with an EXIF orientation flag comes out rotated,
          // which is the classic "why is my photo sideways" bug.
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    } else {
      image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }

    guard let image else {
      throw MediaConversionError.conversionFailed(reason: "the image could not be decoded")
    }
    guard
      let imageDestination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: destination) as CFURL, type.identifier as CFString, 1, nil
      )
    else {
      throw MediaConversionError.unsupportedFormat(type.identifier)
    }

    CGImageDestinationAddImage(
      imageDestination, image,
      [
        kCGImageDestinationLossyCompressionQuality: quality
      ] as CFDictionary)

    guard CGImageDestinationFinalize(imageDestination) else {
      throw MediaConversionError.conversionFailed(reason: "the image could not be written")
    }
  }

  /// Pixel dimensions without decoding the image.
  ///
  /// Replaces `mdls "<path>"`, which spawns a process and parses its output. This reads the
  /// header only, so it costs the same for a 50MB photo as for a thumbnail.
  public static func dimensions(of path: String) -> (width: Int, height: Int)? {
    guard
      let source = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, nil
      ),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }

    // EXIF orientations 5–8 mean the stored pixels are rotated 90°, so the displayed
    // dimensions are swapped. Reporting the raw values gives a portrait photo landscape
    // dimensions, and clients lay it out wrongly.
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return (5...8).contains(orientation) ? (height, width) : (width, height)
  }
}

// MARK: - Audio

public enum AudioConverter {

  /// Converts audio between formats.
  ///
  /// Replaces `afconvert`. iMessage voice notes arrive as CAF, which most clients cannot
  /// play, so this is on the path for every voice message.
  public static func convert(
    source: String,
    destination: String,
    to fileType: AVFileType = .m4a,
    preset: String = AVAssetExportPresetAppleM4A
  ) async throws {
    let asset = AVURLAsset(url: URL(fileURLWithPath: source))
    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
      throw MediaConversionError.unsupportedFormat(preset)
    }

    // Overwritten rather than appended to: the exporter refuses to write over an
    // existing file, and a stale one from an interrupted run would otherwise wedge the
    // conversion permanently.
    try? FileManager.default.removeItem(atPath: destination)

    do {
      try await session.export(to: URL(fileURLWithPath: destination), as: fileType)
    } catch {
      throw MediaConversionError.conversionFailed(reason: String(describing: error))
    }
  }

  /// Duration in seconds, for attachment metadata.
  public static func duration(of path: String) async -> Double? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let duration = try? await asset.load(.duration) else { return nil }
    let seconds = CMTimeGetSeconds(duration)
    return seconds.isFinite ? seconds : nil
  }
}

// MARK: - Type identification

public enum FileTypes {

  /// The MIME type for a path.
  ///
  /// Derived from the extension via UTType rather than shelling out to `file`. A type that
  /// cannot be identified is reported as the generic binary type rather than guessed at —
  /// a wrong MIME type makes a client render an attachment as the wrong kind of thing.
  public static func mimeType(for path: String) -> String {
    let ext = (path as NSString).pathExtension
    guard !ext.isEmpty,
      let type = UTType(filenameExtension: ext),
      let mime = type.preferredMIMEType
    else { return "application/octet-stream" }
    return mime
  }

  public static func isImage(_ path: String) -> Bool { conforms(path, to: .image) }
  public static func isAudio(_ path: String) -> Bool { conforms(path, to: .audio) }
  public static func isVideo(_ path: String) -> Bool { conforms(path, to: .movie) }

  private static func conforms(_ path: String, to parent: UTType) -> Bool {
    let ext = (path as NSString).pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
    return type.conforms(to: parent)
  }
}

extension MediaConversionError {
  public var code: String {
    switch self {
    case .unreadableSource: "media.unreadable_source"
    case .unsupportedFormat: "media.unsupported_format"
    case .conversionFailed: "media.conversion_failed"
    }
  }

  public var domain: String { "Media" }

  public var title: String { "Could not convert an attachment" }

  public var body: String {
    switch self {
    case .unreadableSource(let path): "The attachment at \(path) could not be read."
    case .unsupportedFormat(let format): "\(format) is not a format this server converts."
    case .conversionFailed(let reason): reason
    }
  }
}
