//  BlurhashTests
//
//  A blurhash cannot be spot-checked by eye: a wrong one decodes to a plausible-looking
//  smear in the wrong colours rather than to an error. These pin the encoder against
//  properties of the published format and against solid-colour images whose expected output
//  can be derived by hand.

import CoreGraphics
import Foundation
import Testing

@testable import BBSystem

/// A flat RGBA8 buffer of one colour.
func solidPixels(_ red: UInt8, _ green: UInt8, _ blue: UInt8, size: Int = 16) -> [UInt8] {
  var pixels = [UInt8](repeating: 0, count: size * size * 4)
  for index in stride(from: 0, to: pixels.count, by: 4) {
    pixels[index] = red
    pixels[index + 1] = green
    pixels[index + 2] = blue
    pixels[index + 3] = 255
  }
  return pixels
}

/// A two-axis ramp, so every AC component carries real energy.
func gradientPixels(_ size: Int) -> [UInt8] {
  var pixels = [UInt8](repeating: 0, count: size * size * 4)
  for y in 0..<size {
    for x in 0..<size {
      let offset = (y * size + x) * 4
      pixels[offset] = UInt8(x * 255 / (size - 1))
      pixels[offset + 1] = UInt8(y * 255 / (size - 1))
      pixels[offset + 2] = 128
      pixels[offset + 3] = 255
    }
  }
  return pixels
}

@Suite("Blurhash")
struct BlurhashTests {

  /// Builds a solid-colour image, which is the one case where the expected hash is
  /// derivable without reimplementing the transform: every AC component is zero, so the
  /// hash carries only the DC term.
  private func solidImage(
    red: UInt8, green: UInt8, blue: UInt8, size: Int = 16
  ) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      pixels[index] = red
      pixels[index + 1] = green
      pixels[index + 2] = blue
      pixels[index + 3] = 255
    }
    let context = CGContext(
      data: &pixels, width: size, height: size,
      bitsPerComponent: 8, bytesPerRow: size * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
  }

  @Test("base83 digits are positional")
  func base83() {
    #expect(Blurhash.encode83(0, length: 1) == "0")
    #expect(Blurhash.encode83(82, length: 1) == "~")
    // 83 is "10" in base 83 — the first carry.
    #expect(Blurhash.encode83(83, length: 2) == "10")
    #expect(Blurhash.encode83(0, length: 4) == "0000")
  }

  @Test("hash length follows the component count")
  func length() throws {
    // The format's own arithmetic: 1 size digit + 1 maximum digit + 4 DC digits +
    // 2 digits per AC component, of which there are (x * y - 1).
    for (x, y) in [(4, 3), (1, 1), (9, 9), (3, 3)] {
      let hash = try Blurhash.encode(
        solidImage(red: 10, green: 20, blue: 30),
        componentsX: x, componentsY: y)
      #expect(hash.count == 6 + 2 * (x * y - 1), "components \(x)x\(y)")
    }
  }

  @Test("the size flag round-trips the component count")
  func sizeFlag() throws {
    for (x, y) in [(4, 3), (1, 1), (9, 9), (2, 5)] {
      let hash = try Blurhash.encode(
        solidImage(red: 128, green: 128, blue: 128),
        componentsX: x, componentsY: y)
      let flag = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
      )
      .firstIndex(of: hash.first!)!
      #expect(flag % 9 + 1 == x)
      #expect(flag / 9 + 1 == y)
    }
  }

  /// The DC term of a solid image is that colour exactly, so the four DC digits decode
  /// back to the input. This is the check that would catch a linear/sRGB mix-up, which is
  /// the single most likely way to get this wrong — averaging in sRGB makes every hash
  /// come out too dark.
  @Test("a solid colour round-trips through the DC term")
  func solidColourDC() throws {
    for (r, g, b) in [
      (255, 0, 0), (0, 255, 0), (0, 0, 255), (18, 52, 86), (255, 255, 255), (0, 0, 0),
    ] {
      let hash = try Blurhash.encode(
        solidImage(red: UInt8(r), green: UInt8(g), blue: UInt8(b)),
        componentsX: 1, componentsY: 1
      )
      let alphabet = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
      let dc = hash.dropFirst(2).prefix(4).reduce(0) { acc, character in
        acc * 83 + alphabet.firstIndex(of: character)!
      }
      #expect((dc >> 16) & 0xFF == r, "red for \(r),\(g),\(b)")
      #expect((dc >> 8) & 0xFF == g, "green for \(r),\(g),\(b)")
      #expect(dc & 0xFF == b, "blue for \(r),\(g),\(b)")
    }
  }

  /// Vectors from an independent transcription of the reference C implementation.
  ///
  /// Note what a solid colour actually produces: the AC digits are NOT all at the
  /// midpoint. The reference basis functions are `cos(pi * x * i / width)` with no
  /// half-pixel offset, so they are not orthogonal over the pixel grid and the DC term
  /// leaks into every AC component. That looks like a bug and is not one — it is the
  /// published algorithm, and matching it is the whole requirement, since a client
  /// decodes with the same asymmetry and gets the colour back.
  /// Named rather than passed as raw pixels: swift-testing prints every argument, and a
  /// 32x32 RGBA buffer is 4096 numbers in the log for each case.
  enum ReferenceCase: String, CaseIterable, CustomStringConvertible {
    case solidBlue = "solid 100,150,200 at 4x3"
    case solidRed = "solid 255,0,0 at 1x1"
    case solidDark = "solid 18,52,86 at 3x3"
    case gradient = "gradient at 4x3"

    var description: String { rawValue }

    var pixels: [UInt8] {
      switch self {
      case .solidBlue: solidPixels(100, 150, 200)
      case .solidRed: solidPixels(255, 0, 0)
      case .solidDark: solidPixels(18, 52, 86)
      case .gradient: gradientPixels(32)
      }
    }
    var size: Int { self == .gradient ? 32 : 16 }
    var components: (x: Int, y: Int) {
      switch self {
      case .solidBlue: (4, 3)
      case .solidRed: (1, 1)
      case .solidDark: (3, 3)
      case .gradient: (4, 3)
      }
    }
    var expected: String {
      switch self {
      case .solidBlue: "LBBh]8yZfQyZyZkCfQkCfQfQfQfQ"
      case .solidRed: "00TI:j"
      case .solidDark: "K127F4pMfQpMj]fQfQfQfQ"
      case .gradient: "L$Het82swxX8l}WDjte;gJfjfQfj"
      }
    }
  }

  /// Vectors from an independent transcription of the reference C implementation.
  ///
  /// Note what a solid colour actually produces: the AC digits are NOT all at the
  /// midpoint. The reference basis functions are `cos(pi * x * i / width)` with no
  /// half-pixel offset, so they are not orthogonal over the pixel grid and the DC term
  /// leaks into every AC component. That looks like a bug and is not one — it is the
  /// published algorithm, and matching it is the whole requirement, since a client decodes
  /// with the same asymmetry and gets the colour back.
  @Test("matches the reference implementation", arguments: ReferenceCase.allCases)
  func referenceVectors(_ testCase: ReferenceCase) throws {
    let hash = try Blurhash.encode(
      rgba: testCase.pixels,
      width: testCase.size, height: testCase.size,
      componentsX: testCase.components.x, componentsY: testCase.components.y
    )
    #expect(hash == testCase.expected)
  }

  @Test("component counts outside 1...9 are rejected")
  func componentBounds() {
    let image = solidImage(red: 1, green: 2, blue: 3)
    #expect(throws: Blurhash.BlurhashError.self) {
      try Blurhash.encode(image, componentsX: 0, componentsY: 3)
    }
    #expect(throws: Blurhash.BlurhashError.self) {
      try Blurhash.encode(image, componentsX: 4, componentsY: 10)
    }
  }

  @Test("a gradient produces AC energy and a real maximum")
  func gradient() throws {
    let size = 32
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0..<size {
      for x in 0..<size {
        let offset = (y * size + x) * 4
        pixels[offset] = UInt8(x * 255 / (size - 1))
        pixels[offset + 1] = UInt8(y * 255 / (size - 1))
        pixels[offset + 2] = 128
        pixels[offset + 3] = 255
      }
    }
    let context = CGContext(
      data: &pixels, width: size, height: size,
      bitsPerComponent: 8, bytesPerRow: size * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let hash = try Blurhash.encode(context.makeImage()!, componentsX: 4, componentsY: 3)

    #expect(hash.count == 6 + 2 * 11)
    // The maximum digit is nonzero, and the AC digits are not all at the midpoint.
    #expect(hash.dropFirst(1).prefix(1) != "0")
    #expect(String(hash.dropFirst(6)) != String(repeating: "LL", count: 11))
  }
}
