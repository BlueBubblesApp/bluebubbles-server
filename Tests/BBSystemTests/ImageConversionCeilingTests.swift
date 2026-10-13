//  ImageConversionCeilingTests
//  Converting an image always has a pixel ceiling, and the ceiling does not change the output.
//
//  `MediaConversion.convert` had two branches: with a `maximumDimension` it went through
//  ImageIO's thumbnail path, and without one it called `CGImageSourceCreateImageAtIndex` — a
//  full-resolution decode. The docstring claimed the thumbnail path and described only the
//  first branch, and the second is the COMMON case: it is what `GET /attachment/:guid/download`
//  takes with no `width`/`height`, on an iPhone photo, which is the most frequent attachment
//  request in the product. A 12 MP HEIC is 4032×3024×4 = 48.8 MB of RGBA for a ~2 MB file,
//  held live while the JPEG encodes beside it.
//
//  The fix uses the image's own longest edge as the ceiling when the caller names none, so
//  ImageIO may subsample rather than materialise the whole bitmap. That only counts as a fix
//  if the OUTPUT is unchanged, which is what most of this file asserts: a conversion that
//  quietly started downscaling every attachment would be a far worse bug than the one it
//  replaced, and it would be invisible to any test that only checked the file was written.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BBSystem

@Suite("Image conversion ceiling")
struct ImageConversionCeilingTests {

  /// Writes a real image of a given size, so dimensions can be asserted rather than assumed.
  private func writeImage(width: Int, height: Int) throws -> String {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-ceiling-\(UUID().uuidString).png").path
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // Something non-uniform, so a resize would be visible in the bytes as well as the size.
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))

    let image = try #require(context.makeImage())
    let destination = try #require(
      CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return path
  }

  private func size(of path: String) throws -> (width: Int, height: Int) {
    try #require(ImageConverter.dimensions(of: path))
  }

  @Test("Converting without a ceiling keeps the image at its own size")
  func noCeilingPreservesDimensions() throws {
    // The property that makes the change safe. The unbounded branch is gone, so every
    // conversion now goes through the thumbnail path — and a thumbnail whose ceiling is the
    // image's own longest edge is the image.
    let source = try writeImage(width: 640, height: 400)
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-ceiling-\(UUID().uuidString).jpg").path

    try ImageConverter.convert(source: source, destination: destination, to: .jpeg)

    let converted = try size(of: destination)
    #expect(converted.width == 640)
    #expect(converted.height == 400)
  }

  @Test("A non-square image is not squashed")
  func aspectRatioIsPreserved() throws {
    // A ceiling applied to the SHORT edge would fit inside the assertion above if the image
    // were square, so this one deliberately is not.
    let source = try writeImage(width: 800, height: 200)
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-ceiling-\(UUID().uuidString).jpg").path

    try ImageConverter.convert(source: source, destination: destination, to: .jpeg)

    let converted = try size(of: destination)
    #expect(converted.width == 800)
    #expect(converted.height == 200)
  }

  @Test("An explicit ceiling still downscales, on the longest edge")
  func explicitCeilingStillApplies() throws {
    // The branch that always worked has to keep working: the change removed the OTHER one.
    let source = try writeImage(width: 800, height: 400)
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-ceiling-\(UUID().uuidString).jpg").path

    try ImageConverter.convert(
      source: source, destination: destination, to: .jpeg, maximumDimension: 200)

    let converted = try size(of: destination)
    #expect(converted.width == 200)
    #expect(converted.height == 100, "the aspect ratio should be preserved")
  }

  @Test("A ceiling larger than the image does not upscale it")
  func largerCeilingDoesNotUpscale() throws {
    let source = try writeImage(width: 120, height: 90)
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-ceiling-\(UUID().uuidString).jpg").path

    try ImageConverter.convert(
      source: source, destination: destination, to: .jpeg, maximumDimension: 4000)

    let converted = try size(of: destination)
    #expect(converted.width == 120)
    #expect(converted.height == 90)
  }

  // MARK: - The ceiling itself

  @Test("The longest edge is read from the header")
  func longestEdgeReadsTheHeader() throws {
    let path = try writeImage(width: 640, height: 400)
    let source = try #require(
      CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
    #expect(ImageConverter.longestEdge(of: source) == 640)
  }

  @Test("A header that cannot be read still yields a bound")
  func unreadableHeaderIsStillBounded() throws {
    // The one case that could reintroduce an unbounded decode. An image whose size ImageIO
    // will not report is exactly the one not to hand a full-resolution decode, so the
    // fallback is a large number rather than "no ceiling".
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-ceiling-\(UUID().uuidString).png").path
    try Data("not an image".utf8).write(to: URL(fileURLWithPath: path))
    let source = try #require(
      CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))

    let edge = ImageConverter.longestEdge(of: source)
    #expect(edge > 0, "a bound of zero would produce an empty image")
    #expect(edge <= 16384, "the fallback must still be a bound")
  }
}
