//  AnimatedImageConversionTests
//  An animated image comes out of the converter still animated.
//
//  `ImageConverter.convert` asks ImageIO for index 0, and ImageIO answers for a sequence as
//  readily as for a still: a 45-frame sticker became one JPEG frame with no error anywhere.
//  `convertAnimated` writes every frame with its timing. The fixture is an APNG rather than a
//  HEICS because ImageIO reads one on any Mac and needs an HEVC encoder to write the other,
//  and the container is irrelevant to what is under test: the frame loop and the timing keys.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BBSystem

@Suite("Animated image conversion")
struct AnimatedImageConversionTests {

  /// A real animation on disk: `frames` frames of `edge`×`edge`, each shown for `delay`.
  private func writeAPNG(frames: Int, edge: Int, delay: Double) throws -> String {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-anim-\(UUID().uuidString).png").path
    let destination = try #require(
      CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, frames, nil))
    CGImageDestinationSetProperties(
      destination,
      [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 1]] as CFDictionary)
    for index in 0..<frames {
      let context = try #require(
        CGContext(
          data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(
        CGColor(red: CGFloat(index) / CGFloat(frames), green: 0, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
      CGImageDestinationAddImage(
        destination, try #require(context.makeImage()),
        [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
    return path
  }

  private func source(_ path: String) throws -> CGImageSource {
    try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
  }

  @Test("Every frame is written, as a GIF, with its own delay")
  func framesAndTimingSurvive() throws {
    let input = try writeAPNG(frames: 4, edge: 12, delay: 0.25)
    let output = input + ".gif"
    defer {
      try? FileManager.default.removeItem(atPath: input)
      try? FileManager.default.removeItem(atPath: output)
    }

    try ImageConverter.convertAnimated(source: input, destination: output)

    let gif = try source(output)
    #expect(CGImageSourceGetType(gif) as String? == UTType.gif.identifier)
    #expect(CGImageSourceGetCount(gif) == 4)
    for index in 0..<4 {
      let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(gif, index, nil) as? [CFString: Any])
      let frame = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
      #expect(frame[kCGImagePropertyGIFDelayTime] as? Double == 0.25)
    }
  }

  @Test("The loop count written is forever, whatever the source said")
  func loopsForever() throws {
    // Messages loops a sticker regardless of the container, and the HEICS files it writes
    // say 1, which copied across would play once and freeze on the last frame.
    let input = try writeAPNG(frames: 2, edge: 4, delay: 0.1)
    let output = input + ".gif"
    defer {
      try? FileManager.default.removeItem(atPath: input)
      try? FileManager.default.removeItem(atPath: output)
    }

    try ImageConverter.convertAnimated(source: input, destination: output)

    let properties = try #require(
      CGImageSourceCopyProperties(try source(output), nil) as? [CFString: Any])
    let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
    #expect(gif[kCGImagePropertyGIFLoopCount] as? Int == 0)
  }

  @Test("A ceiling scales every frame")
  func ceilingAppliesToEveryFrame() throws {
    let input = try writeAPNG(frames: 3, edge: 64, delay: 0.1)
    let output = input + ".gif"
    defer {
      try? FileManager.default.removeItem(atPath: input)
      try? FileManager.default.removeItem(atPath: output)
    }

    try ImageConverter.convertAnimated(source: input, destination: output, maximumDimension: 16)

    let gif = try source(output)
    for index in 0..<3 {
      let frame = try #require(CGImageSourceCreateImageAtIndex(gif, index, nil))
      #expect(frame.width == 16)
      #expect(frame.height == 16)
    }
  }

  @Test("A frame with no timing gets a tenth of a second")
  func frameDelayFallsBack() throws {
    // A still PNG has no animation dictionary at all.
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-still-\(UUID().uuidString).png").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let destination = try #require(
      CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
    let context = try #require(
      CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))

    #expect(ImageConverter.frameDelay(of: try source(path), at: 0) == 0.1)
  }

  @Test("Something that is not an image is refused, not written")
  func unreadableSourceThrows() throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-junk-\(UUID().uuidString).heics").path
    try Data("not an image".utf8).write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(throws: MediaConversionError.self) {
      try ImageConverter.convertAnimated(source: path, destination: path + ".gif")
    }
  }
}
