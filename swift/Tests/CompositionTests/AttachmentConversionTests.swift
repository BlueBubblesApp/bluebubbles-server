//  AttachmentConversionTests
//  Attachments are served in a format the client can open.
//
//  `ImageConverter` and `AudioConverter` were built, tested, and wired to nothing:
//  `attachment.download` served the raw file and ignored `original`, `quality`, `width` and
//  `height`. iMessage stores what the sending device produced, so an iPhone photo is HEIC and
//  a voice note is CAF — an Android client asking for a photo got a HEIC it could not render,
//  where every Node server would have handed it a JPEG.
//
//  Verified live against a real HEIC attachment before these were written: the default request
//  now returns `image/jpeg`, and `original=true` returns the untouched HEIC.
//
//  See `.claude/docs/imessage.md`.

import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

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

  @Test("original=true converts nothing")
  func originalIsUntouched() async throws {
    // The escape hatch every client relies on to fetch the real file — for saving to a
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
    // nothing. This is the common case — most attachments are already fine.
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
    // original — a wrong answer that looks like a working request.
    #expect(AttachmentConversion.Options(original: true).original)
    #expect(!AttachmentConversion.Options().original)
  }

  @Test("Resize is requested when any dimension or quality is given")
  func wantsResizeDetection() {
    #expect(AttachmentConversion.Options(width: 100).wantsResize)
    #expect(AttachmentConversion.Options(height: 100).wantsResize)
    #expect(AttachmentConversion.Options(quality: 0.5).wantsResize)
    #expect(!AttachmentConversion.Options().wantsResize)
  }
}
