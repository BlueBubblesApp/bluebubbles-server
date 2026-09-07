//  Blurhash
//  The compact image placeholder clients render while the real attachment loads.
//
//  Replaces the `blurhash` npm package. The algorithm is a short, fully specified one —
//  a discrete cosine transform over a handful of components, base83-encoded — so
//  implementing it directly is cheaper than carrying a dependency for ~120 lines.
//
//  Reference: https://github.com/woltapp/blurhash/blob/master/Algorithm.md
//
//  Correctness matters more than it looks: a hash that decodes to the wrong colours is not
//  an error a client can detect, it just renders a wrong-coloured smear. The round-trip test
//  in BlurhashTests pins the encoding against the reference vectors.

import BBCore
import CoreGraphics
import Foundation
import ImageIO

public enum Blurhash {

  /// The alphabet, in order. Position IS the value, so this string cannot be reordered.
  private static let alphabet = Array(
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
  )

  public enum BlurhashError: BBError, Equatable {
    case unreadableImage(String)
    case invalidComponentCount(x: Int, y: Int)
  }

  /// Encodes an image file.
  ///
  /// The image is downsampled first. The transform is O(width x height x components), and
  /// running it over a 4032x3024 photo to produce 30 numbers wastes seconds per attachment
  /// — at thumbnail size the output is visually identical, because the whole point is a
  /// blur.
  public static func encode(
    imageAt path: String,
    componentsX: Int = 4,
    componentsY: Int = 3,
    downsampleTo maximumEdge: Int = 64
  ) throws -> String {
    guard (1...9).contains(componentsX), (1...9).contains(componentsY) else {
      throw BlurhashError.invalidComponentCount(x: componentsX, y: componentsY)
    }
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil) else {
      throw BlurhashError.unreadableImage(path)
    }
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
        ] as CFDictionary)
    else {
      throw BlurhashError.unreadableImage(path)
    }
    return try encode(image, componentsX: componentsX, componentsY: componentsY)
  }

  public static func encode(
    _ image: CGImage,
    componentsX: Int = 4,
    componentsY: Int = 3
  ) throws -> String {
    guard (1...9).contains(componentsX), (1...9).contains(componentsY) else {
      throw BlurhashError.invalidComponentCount(x: componentsX, y: componentsY)
    }
    let width = image.width
    let height = image.height
    // Drawn into a known layout rather than read from the image's own buffer: the source
    // could be indexed, 16-bit, CMYK or premultiplied, and reading those as RGBA8 gives
    // silently wrong colours instead of an error.
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &pixels,
        width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw BlurhashError.unreadableImage("could not create a drawing context")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    return try encode(
      rgba: pixels, width: width, height: height,
      componentsX: componentsX, componentsY: componentsY
    )
  }

  /// Encodes from a raw RGBA8 buffer.
  ///
  /// Exposed so the transform can be tested against the reference implementation directly,
  /// with no image decoding in between — the colour-space handling is the part most likely
  /// to be subtly wrong, and it is invisible in the output.
  public static func encode(
    rgba pixels: [UInt8],
    width: Int,
    height: Int,
    componentsX: Int = 4,
    componentsY: Int = 3
  ) throws -> String {
    guard (1...9).contains(componentsX), (1...9).contains(componentsY) else {
      throw BlurhashError.invalidComponentCount(x: componentsX, y: componentsY)
    }

    var factors: [[Double]] = []
    for y in 0..<componentsY {
      for x in 0..<componentsX {
        let normalisation: Double = (x == 0 && y == 0) ? 1 : 2
        factors.append(
          multiplyBasisFunction(
            pixels: pixels, width: width, height: height,
            normalisation: normalisation
          ) { i, j in
            cos(Double.pi * Double(x) * Double(i) / Double(width))
              * cos(Double.pi * Double(y) * Double(j) / Double(height))
          }
        )
      }
    }

    let dc = factors[0]
    let ac = Array(factors.dropFirst())

    var hash = ""
    let sizeFlag = (componentsX - 1) + (componentsY - 1) * 9
    hash += encode83(sizeFlag, length: 1)

    let maximumValue: Double
    if ac.isEmpty {
      hash += encode83(0, length: 1)
      maximumValue = 1
    } else {
      let actualMaximum = ac.flatMap { $0 }.map(abs).max() ?? 0
      // Quantised to 1/166ths, matching the reference. The clamp keeps the quantised
      // value in the single base83 digit the format allots it.
      let quantised = max(0, min(82, Int(floor(actualMaximum * 166 - 0.5))))
      maximumValue = (Double(quantised) + 1) / 166
      hash += encode83(quantised, length: 1)
    }

    hash += encode83(encodeDC(dc), length: 4)
    for component in ac {
      hash += encode83(encodeAC(component, maximumValue: maximumValue), length: 2)
    }
    return hash
  }

  // MARK: - Transform

  private static func multiplyBasisFunction(
    pixels: [UInt8],
    width: Int,
    height: Int,
    normalisation: Double,
    basis: (Int, Int) -> Double
  ) -> [Double] {
    var r = 0.0
    var g = 0.0
    var b = 0.0
    for y in 0..<height {
      let rowStart = y * width * 4
      for x in 0..<width {
        let value = basis(x, y)
        let offset = rowStart + x * 4
        r += value * sRGBToLinear(Int(pixels[offset]))
        g += value * sRGBToLinear(Int(pixels[offset + 1]))
        b += value * sRGBToLinear(Int(pixels[offset + 2]))
      }
    }
    let scale = normalisation / Double(width * height)
    return [r * scale, g * scale, b * scale]
  }

  // MARK: - Colour space
  //
  // The transform runs in LINEAR light, not on the stored sRGB values. Averaging sRGB
  // directly is the classic mistake, and it makes every blur noticeably too dark.

  private static func sRGBToLinear(_ value: Int) -> Double {
    let v = Double(value) / 255
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
  }

  private static func linearToSRGB(_ value: Double) -> Int {
    let v = max(0, min(1, value))
    return v <= 0.0031308
      ? Int(v * 12.92 * 255 + 0.5)
      : Int((1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
  }

  private static func encodeDC(_ value: [Double]) -> Int {
    (linearToSRGB(value[0]) << 16) + (linearToSRGB(value[1]) << 8) + linearToSRGB(value[2])
  }

  private static func encodeAC(_ value: [Double], maximumValue: Double) -> Int {
    func quantise(_ component: Double) -> Int {
      // The signed power curve is part of the format: it gives more precision near
      // zero, where most AC components live.
      let scaled = floor(
        copysign(pow(abs(component) / maximumValue, 0.5), component) * 9 + 9.5
      )
      return max(0, min(18, Int(scaled)))
    }
    return quantise(value[0]) * 19 * 19 + quantise(value[1]) * 19 + quantise(value[2])
  }

  // MARK: - Base83

  static func encode83(_ value: Int, length: Int) -> String {
    var result = ""
    for index in 1...length {
      let digit = (value / Int(pow(83.0, Double(length - index)))) % 83
      result.append(alphabet[digit])
    }
    return result
  }
}

extension Blurhash.BlurhashError {
  public var code: String {
    switch self {
    case .unreadableImage: "blurhash.unreadable_image"
    case .invalidComponentCount: "blurhash.invalid_component_count"
    }
  }

  public var domain: String { "Media" }

  public var title: String { "Could not build an image preview" }

  public var body: String {
    switch self {
    case .unreadableImage(let detail): detail
    case .invalidComponentCount(let x, let y):
      "A blurhash needs between 1 and 9 components on each axis; \(x)×\(y) is outside that."
    }
  }
}
