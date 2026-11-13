//  AttachmentConversionTests
//  Attachments are served in a format the client can open.
//
//  `ImageConverter` and `AudioConverter` were built, tested, and wired to nothing:
//  `attachment.download` served the raw file and ignored `original`, `quality`, `width` and
//  `height`. iMessage stores what the sending device produced, so an iPhone photo is HEIC and
//  a voice note is CAF: an Android client asking for a photo got a HEIC it could not render,
//  where every Node server would have handed it a JPEG.
//
//  Verified live against a real HEIC attachment before these were written: the default request
//  now returns `image/jpeg`, and `original=true` returns the untouched HEIC.
//
//  WHICH format comes back is decided from the file, by `AttachmentDelivery`: a sticker is
//  `image/heic` with alpha and became a JPEG on a black square; an animated sticker is a
//  45-frame `image/heic-sequence` and became its first frame, with no error, because ImageIO
//  decodes frame 0 of a sequence happily. The fixtures for those are PNGs and APNGs built on the
//  spot, with the row claiming HEIC, so they run on a CI Mac with no HEVC encoder; the two tests
//  on real HEIC and HEICS files run where ImageIO can write them.
//
//  See `.claude/docs/imessage.md`.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BBAppStore
@testable import BBInterfaces
@testable import BBMedia
@testable import BBSerialization

@Suite("Attachment conversion")
struct AttachmentConversionTests {

  private func makeConversion() -> (AttachmentConversion, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-conv-\(UUID().uuidString)")
    return (AttachmentConversion(cacheDirectory: directory), directory)
  }

  /// A real, tiny PNG. Written to disk because every path here checks the file exists and
  /// reads its type from the bytes.
  private func writePNG() throws -> String {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-\(UUID().uuidString).png").path
    let base64 = """
      iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
      """
    try #require(Data(base64Encoded: base64)).write(to: URL(fileURLWithPath: path))
    return path
  }

  /// A real image in `container`, with or without alpha, one or several frames.
  private func writeImage(
    container: UTType, alpha: Bool, frames: Int = 1, edge: Int = 8
  ) throws -> String {
    let ext = container.preferredFilenameExtension ?? "img"
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-\(UUID().uuidString).\(ext)").path
    let destination = try #require(
      CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, container.identifier as CFString, frames, nil))
    for index in 0..<frames {
      let context = try #require(
        CGContext(
          data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
      // Half the canvas is left clear when alpha is asked for: an alpha channel that is
      // opaque everywhere is one an encoder may drop, and HEIC's does.
      context.setFillColor(CGColor(red: CGFloat(index) / 8, green: 0.4, blue: 0.9, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: alpha ? edge / 2 : edge, height: edge))
      CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    }
    #expect(CGImageDestinationFinalize(destination))
    return path
  }

  /// Whether ImageIO on this Mac can WRITE a container. Reading one is universal; writing a
  /// HEIC or HEICS needs an HEVC encoder, which a CI Mac may not have.
  private static func canWrite(_ container: String) -> Bool {
    ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(container)
  }

  private func frameCount(_ path: String) -> Int {
    CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).map(CGImageSourceGetCount)
      ?? -1
  }

  @Test("An image with alpha is re-encoded as PNG, not JPEG")
  func alphaBecomesPNG() async throws {
    // A sticker. The row says `image/heic` exactly as a photo's does; only the file knows.
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = try writeImage(container: .png, alpha: true)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = await conversion.resolve(path: path, mimeType: "image/heic", options: .init())
    #expect(resolved.mimeType == "image/png")
    #expect(resolved.format == .png)
    #expect(resolved.path.hasSuffix(".png"))
    #expect(
      AttachmentMetadataReader.imageTraits(at: URL(fileURLWithPath: resolved.path))?.hasAlpha
        == true, "the alpha channel must survive the conversion")
  }

  @Test("An image without alpha is re-encoded as JPEG")
  func opaqueBecomesJPEG() async throws {
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = try writeImage(container: .png, alpha: false)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = await conversion.resolve(path: path, mimeType: "image/heic", options: .init())
    #expect(resolved.mimeType == "image/jpeg")
    #expect(resolved.format == .jpeg)
  }

  @Test("A sequence is re-encoded as an animated GIF with every frame")
  func sequenceBecomesGIF() async throws {
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = try writeImage(container: .png, alpha: true, frames: 5)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = await conversion.resolve(
      path: path, mimeType: "image/heic-sequence", options: .init())
    #expect(resolved.mimeType == "image/gif")
    #expect(resolved.format == .gif)
    #expect(frameCount(resolved.path) == 5, "a still of frame 0 is the bug this exists to stop")
  }

  @Test("A resize keeps the format the client was told")
  func resizeKeepsFormat() async throws {
    // The serializer said `image/png`; a smaller one is still a PNG, with its alpha.
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = try writeImage(container: .png, alpha: true, edge: 32)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = await conversion.resolve(
      path: path, mimeType: "image/png", options: .init(width: 8))
    #expect(resolved.mimeType == "image/png")
    let source = try #require(
      CGImageSourceCreateWithURL(URL(fileURLWithPath: resolved.path) as CFURL, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    #expect(properties?[kCGImagePropertyPixelWidth] as? Int == 8)
  }

  @Test("The download overload performs the decision it is handed")
  func downloadOverloadPerformsTheDecision() async throws {
    // What the serializer reported is what the download does: the same `AttachmentDelivery`
    // goes in, so the client's `mimeType` and the bytes agree by construction.
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = try writeImage(container: .png, alpha: true)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = await conversion.resolve(
      path: path, mimeType: "image/heic", delivery: AttachmentDelivery(format: .png),
      traits: nil, options: .init())
    #expect(resolved.mimeType == "image/png")
    #expect(resolved.format == .png)

    let untouched = await conversion.resolve(
      path: path, mimeType: "image/heic", delivery: nil, traits: nil, options: .init())
    #expect(untouched.path == path, "no decision, no conversion")
    #expect(untouched.format == nil)
  }

  @Test(
    "A real HEIC sticker becomes a PNG",
    .enabled(if: canWrite("public.heic"), "ImageIO here has no HEIC encoder"))
  func realHEICStickerBecomesPNG() async throws {
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = try writeImage(container: .heic, alpha: true)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = await conversion.resolve(path: path, mimeType: "image/heic", options: .init())
    #expect(resolved.mimeType == "image/png")
  }

  @Test(
    "A real HEICS sticker becomes an animated GIF",
    .enabled(if: canWrite("public.heics"), "ImageIO here has no HEICS encoder"))
  func realHEICSStickerBecomesGIF() async throws {
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }
    let heics = try #require(UTType("public.heics"))
    let path = try writeImage(container: heics, alpha: true, frames: 3)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = await conversion.resolve(
      path: path, mimeType: "image/heic-sequence", options: .init())
    #expect(resolved.mimeType == "image/gif")
    #expect(frameCount(resolved.path) == 3)
  }

  @Test("original=true converts nothing")
  func originalIsUntouched() async throws {
    // The escape hatch every client relies on to fetch the real file: for saving to a
    // photo library, or for a client that CAN read HEIC and wants the quality.
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = try writePNG()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = await conversion.resolve(
      path: path,
      mimeType: "image/heic",
      options: .init(original: true, width: 100)
    )
    #expect(resolved.path == path)
    #expect(resolved.mimeType == "image/heic")
  }

  @Test("A widely-supported image is served as-is when no size is requested")
  func supportedImageIsNotReEncoded() async throws {
    // Re-encoding a JPEG that nobody asked to resize costs CPU and loses quality for
    // nothing. This is the common case: most attachments are already fine.
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = try writePNG()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = await conversion.resolve(
      path: path, mimeType: "image/png", options: .init()
    )
    #expect(resolved.path == path, "an unmodified PNG should not be re-encoded")
  }

  @Test("A GIF is never converted, even when a size is requested")
  func gifsAreLeftAlone() async throws {
    // Converting a GIF to JPEG keeps ONE frame, so an animation silently becomes a still.
    // Node excludes them for the same reason.
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = try writePNG()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = await conversion.resolve(
      path: path, mimeType: "image/gif", options: .init(width: 50)
    )
    #expect(resolved.mimeType == "image/gif")
    #expect(resolved.path == path)
  }

  @Test("An unreadable file is served rather than refused")
  func conversionFailureFallsBack() async throws {
    // A photo that will not transcode should still arrive. Refusing turns a cosmetic
    // problem into a missing attachment, which is strictly worse for the user.
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-\(UUID().uuidString).heic").path
    try Data("not an image".utf8).write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = await conversion.resolve(
      path: path, mimeType: "image/heic", options: .init()
    )
    #expect(resolved.path == path, "a failed conversion must still serve the original")
  }

  @Test("A missing file is not treated as convertible")
  func missingFileIsPassedThrough() async {
    let (conversion, directory) = makeConversion()
    defer { try? FileManager.default.removeItem(at: directory) }

    let resolved = await conversion.resolve(
      path: "/nonexistent/attachment.heic", mimeType: "image/heic", options: .init()
    )
    #expect(resolved.path == "/nonexistent/attachment.heic")
  }

  @Test("Truthy query spellings all mean the same thing")
  func truthyParsing() {
    // Clients have spelled these three ways for years. Accepting only "true" would
    // silently ignore two of them and convert a file for a caller who asked for the
    // original: a wrong answer that looks like a working request.
    #expect(AttachmentConversion.Options(original: true).original)
    #expect(!AttachmentConversion.Options().original)
  }

  @Test("Resize is requested when any dimension or quality is given")
  func wantsResizeDetection() {
    #expect(AttachmentConversion.Options(width: 100).wantsResize)
    #expect(AttachmentConversion.Options(height: 100).wantsResize)
    #expect(AttachmentConversion.Options(quality: .good).wantsResize)
    #expect(!AttachmentConversion.Options().wantsResize)
  }
}
