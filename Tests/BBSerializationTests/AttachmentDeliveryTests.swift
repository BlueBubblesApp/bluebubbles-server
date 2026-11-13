//  AttachmentDeliveryTests
//  What the serializer says an attachment is, and what the download serves, come from one
//  decision made from the file.
//
//  A client that reads `image/hei…` runs its own HEIC decoder on the file it is given, and a
//  JPEG under that name fails it. The reference reports a converted attachment's type and name
//  as the converted ones, so its clients are told JPEG and handed JPEG. `AttachmentDelivery` is
//  the one function the serializer and the download here both ask, so they cannot disagree.
//
//  The decision is from the file, not the row: an `image/heic` row is a photo or a sticker, and
//  only the header knows which. Every fixture here is a PNG or an APNG built on the spot, with
//  the row CLAIMING another type, because that is the shape of the bug and because an HEVC
//  encoder is not something every CI machine has.

import BBIMessage
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BBSerialization

@Suite("Attachment delivery")
struct AttachmentDeliveryTests {

  /// A real image on disk, with or without an alpha channel, one or several frames.
  private func image(alpha: Bool, frames: Int = 1) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-delivery-\(UUID().uuidString).png")
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, frames, nil))
    if frames > 1 {
      CGImageDestinationSetProperties(
        destination,
        [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
    }
    for index in 0..<frames {
      let context = try #require(
        CGContext(
          data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
      // Half the canvas is left clear when alpha is asked for: an alpha channel that is
      // opaque everywhere is one an encoder may drop.
      context.setFillColor(CGColor(red: CGFloat(index) / 4, green: 0.5, blue: 0.2, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: alpha ? 4 : 8, height: 8))
      let frame = try #require(context.makeImage())
      CGImageDestinationAddImage(
        destination, frame,
        frames > 1
          ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.25]] as CFDictionary
          : nil)
    }
    #expect(CGImageDestinationFinalize(destination))
    return url
  }

  private func row(
    path: String?, mime: String?, uti: String? = nil, transferState: Int = 5
  ) throws -> AttachmentRow {
    try Rows.attachment(
      guid: UUID().uuidString, mimeType: mime, filename: path, uti: uti,
      transferState: transferState)
  }

  // MARK: The decision

  @Test("A photo without alpha becomes a JPEG")
  func photoIsJPEG() {
    let traits = ImageTraits(frameCount: 1, hasAlpha: false, container: "public.heic")
    #expect(
      AttachmentDelivery.plan(kind: .image, mimeType: "image/heic", traits: traits)?.format
        == .jpeg)
  }

  @Test("An image with alpha becomes a PNG, whatever the row calls it")
  func alphaIsPNG() {
    // A sticker is `image/heic` exactly like a photo. Flattened to JPEG it sat on a black
    // square.
    let traits = ImageTraits(frameCount: 1, hasAlpha: true, container: "public.heic")
    #expect(
      AttachmentDelivery.plan(kind: .image, mimeType: "image/heic", traits: traits)?.format
        == .png)
  }

  @Test("A sequence becomes a GIF, and animation outranks alpha")
  func sequenceIsGIF() {
    // An animated sticker has alpha too; a PNG of it would be frame 0, a still.
    let traits = ImageTraits(frameCount: 45, hasAlpha: true, container: "public.heics")
    #expect(
      AttachmentDelivery.plan(kind: .image, mimeType: "image/heic-sequence", traits: traits)?
        .format == .gif)
  }

  @Test("Several images in a container that does not play them are not an animation")
  func pagesAreNotFrames() {
    let tiff = ImageTraits(frameCount: 3, hasAlpha: false, container: UTType.tiff.identifier)
    #expect(!tiff.isAnimated)
    #expect(
      AttachmentDelivery.plan(kind: .image, mimeType: "image/tiff", traits: tiff)?.format
        == .jpeg)
  }

  @Test("A widely supported image is served as stored")
  func supportedImageIsOriginal() {
    let traits = ImageTraits(frameCount: 1, hasAlpha: true, container: UTType.png.identifier)
    #expect(AttachmentDelivery.plan(kind: .image, mimeType: "image/png", traits: traits) == nil)
    #expect(AttachmentDelivery.plan(kind: .image, mimeType: "image/jpeg", traits: traits) == nil)
  }

  @Test("An image ImageIO cannot open is served as stored")
  func unreadableIsOriginal() {
    // The conversion would fail and serve the original; the reference reports the stored row
    // for a file its conversion refuses.
    #expect(AttachmentDelivery.plan(kind: .image, mimeType: "image/heic", traits: nil) == nil)
  }

  @Test("A CAF voice note becomes M4A; a video and a document are never converted")
  func audioAndTheRest() {
    #expect(
      AttachmentDelivery.plan(kind: .audio, mimeType: "audio/x-caf", traits: nil)?.format == .m4a)
    #expect(AttachmentDelivery.plan(kind: .audio, mimeType: "audio/mp4", traits: nil) == nil)
    #expect(AttachmentDelivery.plan(kind: .video, mimeType: "video/quicktime", traits: nil) == nil)
    #expect(AttachmentDelivery.plan(kind: nil, mimeType: "application/pdf", traits: nil) == nil)
  }

  @Test("A resize keeps the format the client was told, where ImageIO can write it")
  func resizeKeepsFormat() {
    let alpha = ImageTraits(frameCount: 1, hasAlpha: true, container: UTType.webP.identifier)
    #expect(AttachmentDelivery.resizeFormat(mimeType: "image/jpeg", traits: alpha) == .jpeg)
    #expect(AttachmentDelivery.resizeFormat(mimeType: "image/png", traits: nil) == .png)
    // No WebP encoder, so WebP is decided like a conversion.
    #expect(AttachmentDelivery.resizeFormat(mimeType: "image/webp", traits: alpha) == .png)
  }

  // MARK: The spelling

  @Test("The reported name is the stored name plus the new extension, the reference's spelling")
  func transferNameSpelling() {
    // The transfer name, or the GUID when there is none, plus `.jpeg`, unless it already ends
    // in it.
    let jpeg = AttachmentDelivery(format: .jpeg)
    #expect(jpeg.transferName(for: "IMG_0001.heic", guid: "g") == "IMG_0001.heic.jpeg")
    #expect(jpeg.transferName(for: "already.jpeg", guid: "g") == "already.jpeg")
    #expect(jpeg.transferName(for: nil, guid: "at_0_ABCD") == "at_0_ABCD.jpeg")
    #expect(jpeg.transferName(for: "", guid: "at_0_ABCD") == "at_0_ABCD.jpeg")
    #expect(
      AttachmentDelivery(format: .gif).transferName(for: "sticker.heics", guid: "g")
        == "sticker.heics.gif")
  }

  // MARK: Through the reader

  @Test("The reader decides from the file, not from the row's mime type")
  func readerDecidesFromTheFile() async throws {
    let alpha = try image(alpha: true)
    let opaque = try image(alpha: false)
    let animated = try image(alpha: true, frames: 3)
    defer {
      for url in [alpha, opaque, animated] { try? FileManager.default.removeItem(at: url) }
    }
    let reader = AttachmentMetadataReader()

    // All three rows CLAIM a type the client cannot open; the file decides what it becomes.
    let sticker = try row(path: alpha.path, mime: "image/heic")
    let photo = try row(path: opaque.path, mime: "image/heic")
    let sequence = try row(path: animated.path, mime: "image/heic-sequence")
    #expect(await reader.delivery(for: sticker)?.format == .png)
    #expect(await reader.delivery(for: photo)?.format == .jpeg)
    #expect(await reader.delivery(for: sequence)?.format == .gif)
  }

  @Test("A file that is not on disk is served as stored")
  func missingFileIsOriginal() async throws {
    // The reference converts only a file it finds. A client told JPEG for bytes that are not
    // there would ask for a JPEG the download cannot make.
    let reader = AttachmentMetadataReader()
    let missing = try row(path: "/nonexistent/\(UUID().uuidString).heic", mime: "image/heic")
    #expect(await reader.delivery(for: missing) == nil)
  }

  @Test("A row with no mime type is typed from its extension")
  func effectiveMimeType() throws {
    let m4a = try row(path: "~/Library/Messages/Attachments/note.m4a", mime: nil)
    #expect(AttachmentMetadataReader.effectiveMimeType(for: m4a) == "audio/x-m4a")
    let none = try row(path: "~/Library/Messages/Attachments/blob", mime: nil)
    #expect(AttachmentMetadataReader.effectiveMimeType(for: none) == "application/octet-stream")
    let given = try row(path: "~/Library/Messages/Attachments/a.bin", mime: "image/heic")
    #expect(AttachmentMetadataReader.effectiveMimeType(for: given) == "image/heic")
  }

  @Test("A CAF voice note is typed by its UTI, and the system has no mime type for it")
  func cafIsAudioByUTI() throws {
    // The row carries no mime type and the type system knows none, so the fallback is the
    // generic binary type; the UTI is what makes it audio, and that is what the decision
    // needs.
    let caf = try row(
      path: "~/Library/Messages/Attachments/note.caf", mime: nil,
      uti: "com.apple.coreaudio-format")
    #expect(AttachmentMetadataReader.effectiveMimeType(for: caf) == "application/octet-stream")
    #expect(AttachmentMetadataReader.kind(of: caf) == .audio)
    #expect(
      AttachmentDelivery.plan(
        kind: .audio, mimeType: AttachmentMetadataReader.effectiveMimeType(for: caf),
        traits: nil)?.format == .m4a)
  }

  @Test("The traits ride along with a metadata read and never reach the wire")
  func traitsAreNotOnTheWire() async throws {
    let url = try image(alpha: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let metadata = try #require(
      await AttachmentMetadataReader().metadata(for: row(path: url.path, mime: "image/png")))
    #expect(metadata.imageTraits?.hasAlpha == true)
    #expect(metadata.imageTraits?.frameCount == 1)
    #expect(metadata.json().objectKeys.sorted() == ["height", "size", "width"])
  }

  // MARK: Through the serializer

  @Test("The serializer reports the served type and name, and leaves the UTI alone")
  func serializerReportsWhatIsServed() throws {
    let row = try Rows.attachment(mimeType: "image/heic", uti: "public.heic")
    let json = AttachmentSerializer.serialize(
      row, hasLivePhoto: false, delivery: AttachmentDelivery(format: .jpeg))
    #expect(json["mimeType"]?.stringValue == "image/jpeg")
    #expect(json["transferName"]?.stringValue == "a.png.jpeg")
    // `uti` is not rewritten, there or here: it says what the sender produced.
    #expect(json["uti"]?.stringValue == "public.heic")

    let notification = AttachmentSerializer.serialize(
      row, hasLivePhoto: false, delivery: AttachmentDelivery(format: .jpeg),
      isForNotification: true)
    #expect(notification["mimeType"]?.stringValue == "image/jpeg")
  }

  @Test("convertAttachments=false reports the row as stored")
  func convertOffReportsTheRow() throws {
    let row = try Rows.attachment(mimeType: "image/heic", uti: "public.heic")
    let json = AttachmentSerializer.serialize(
      row, config: AttachmentSerializerConfig(convert: false), hasLivePhoto: false,
      delivery: AttachmentDelivery(format: .jpeg))
    #expect(json["mimeType"]?.stringValue == "image/heic")
    #expect(json["transferName"]?.stringValue == "a.png")
  }

  @Test("A message context carries the decision for every attachment it loads")
  func contextLoadsDelivery() async throws {
    let url = try image(alpha: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let heic = try row(path: url.path, mime: "image/heic")
    let jpeg = try row(path: url.path, mime: "image/jpeg")

    var context = MessageSerializer.Context()
    // Metadata off, as an event's context loads it: the decision is still made, because
    // `mimeType` is always emitted.
    await context.load(
      attachments: [heic, jpeg], from: AttachmentMetadataReader(), withMetadata: false)
    #expect(context.attachmentDelivery[heic.guid]?.format == .png)
    #expect(context.attachmentDelivery[jpeg.guid] == nil)
    #expect(context.attachmentMetadata.isEmpty)
  }
}
