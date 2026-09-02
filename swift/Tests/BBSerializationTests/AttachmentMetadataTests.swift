//  AttachmentMetadataTests
//  `height`, `width` and `metadata` come from the file, not from a placeholder.
//
//  They were a placeholder: `AttachmentSerializer` took a `dimensions` parameter that neither
//  call site passed, so every attachment on every route answered `height: 0, width: 0,
//  metadata: {}`. The KEY SET was right, so the parity replay could not see it — it compares
//  shape, and the shape was correct. It took sending a real 16×16 PNG and reading back zeroes.
//
//  The per-type key names are the fiddly part and are the reference's, not ours: an image's
//  file size is `size`, an audio or video file's is `bytes`.

import BBIMessage
import Foundation
import ImageIO
import Testing

@testable import BBSerialization

@Suite("Attachment metadata")
struct AttachmentMetadataTests {

  /// A real 16×16 PNG on disk, because what is under test is reading a file.
  private func png() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-meta-\(UUID().uuidString).png")
    // Built rather than committed: a binary fixture for sixteen pixels is not worth a file.
    let image = CGContext(
      data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!.makeImage()!
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
  }

  /// Through the shared builder, so there is one way to make a row in this target.
  private func row(
    path: String?, mime: String?, uti: String? = nil, transferState: Int = 5
  ) -> AttachmentRow {
    Rows.attachment(
      guid: UUID().uuidString, mimeType: mime, filename: path, uti: uti,
      transferState: transferState
    )
  }

  @Test("An image reports its real dimensions and size under the reference's key names")
  func readsImageDimensions() async throws {
    let url = try png()
    defer { try? FileManager.default.removeItem(at: url) }

    let metadata = try #require(
      await AttachmentMetadataReader().metadata(
        for: row(path: url.path, mime: "image/png"))
    )
    #expect(metadata.height == 16)
    #expect(metadata.width == 16)
    #expect((metadata.byteSize ?? 0) > 0)

    // `size` for an image — `bytes` is the audio and video spelling.
    let json = metadata.json()
    #expect(json.objectKeys.sorted() == ["height", "size", "width"])
    #expect(json["height"]?.intValue == 16)
  }

  @Test("Audio and video call the same field `bytes`, as the reference does")
  func perTypeKeyNames() {
    let audio = AttachmentMetadata(kind: .audio, byteSize: 12, duration: 1.5).json()
    #expect(audio.objectKeys.sorted() == ["bytes", "duration"])
    let image = AttachmentMetadata(kind: .image, byteSize: 12).json()
    #expect(image.objectKeys.sorted() == ["size"])
  }

  /// Three states, and they are not interchangeable. A strict client notices the difference
  /// between "we looked and found nothing" and "this kind has none".
  @Test("metadata is an object, null, or absent — never all three the same")
  func threeStates() async throws {
    let url = try png()
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = AttachmentMetadataReader()
    let config = AttachmentSerializerConfig(loadMetadata: true)

    let image = row(path: url.path, mime: "image/png")
    let read = AttachmentSerializer.serialize(
      image, config: config, metadata: await reader.metadata(for: image))
    #expect(read["metadata"]?.objectKeys.isEmpty == false)
    #expect(read["height"]?.intValue == 16)

    // An image whose file is gone: we looked, and there was nothing.
    let missing = row(path: "/nonexistent/gone.png", mime: "image/png")
    let absent = AttachmentSerializer.serialize(
      missing, config: config, metadata: await reader.metadata(for: missing))
    #expect(absent["metadata"] == .null)
    #expect(absent["height"]?.intValue == 0)

    // A PDF: not a medium with dimensions, so the reference emits no key at all.
    let pdf = row(path: url.path, mime: "application/pdf")
    let none = AttachmentSerializer.serialize(
      pdf, config: config, metadata: await reader.metadata(for: pdf))
    #expect(none["metadata"] == nil)
    #expect(none["height"]?.intValue == 0)
  }

  /// A transfer still in flight is not cached: `transferState` moves and the dimensions
  /// arrive with it, so caching an early read would pin the zeroes for the life of the
  /// process.
  @Test("An unfinished transfer is re-read rather than cached")
  func doesNotCacheAnUnfinishedTransfer() async throws {
    let url = try png()
    let reader = AttachmentMetadataReader()
    let pending = row(path: url.path, mime: "image/png", transferState: 1)

    #expect(await reader.metadata(for: pending)?.height == 16)
    try FileManager.default.removeItem(at: url)
    // Re-read, so the file being gone now shows. A cached answer would still say 16.
    #expect(await reader.metadata(for: pending) == nil)
  }
}
