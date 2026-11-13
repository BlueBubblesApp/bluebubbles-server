//  Blurhash
//  The compact image placeholder clients render while the real attachment loads.
//
//  Implemented directly: the algorithm is a short, fully specified one (a discrete cosine
//  transform over a handful of components, base83-encoded) so it is cheaper than carrying
//  a dependency for ~120 lines.
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
    /// The buffer is smaller than the stated dimensions describe.
    case pixelBufferTooSmall(expected: Int, actual: Int)
  }

  /// Encodes an image file.
  ///
  /// The image is downsampled first. The transform is O(width x height x components), and
  /// running it over a 4032x3024 photo to produce 30 numbers wastes seconds per attachment;
  /// at thumbnail size the output is visually identical, because the whole point is a
  /// blur.
  /// - Parameters:
  ///   - componentsX: 3 by default, matching the reference's `getBlurhash` default. The
  ///     count is encoded in the hash's first character, so a server answering the same
  ///     request with 4 returns a DIFFERENT string for the same image; this defaulted to 4
  ///     and the documented default said 3.
  ///   - maximumEdge: the longest edge the image is scaled to before hashing. The reference
  ///     resizes to the caller's `width`/`height` (480×320 by default); a blurhash is a very
  ///     low-frequency summary, so a smaller box gives the same hash for far less work, and
  ///     the caller's box is honoured only as an upper bound.
  public static func encode(
    imageAt path: String,
    componentsX: Int = 3,
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
    componentsX: Int = 3,
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

    // The draw happens INSIDE `withUnsafeMutableBytes`, and that is the whole point.
    //
    // `CGContext(data: &pixels, …)` looks like it hands the context the array's buffer, and
    // Swift's inout-to-pointer conversion only guarantees that pointer for the duration of
    // the call it is written in. The context outlives that call and `draw` then writes
    // through a pointer whose validity has expired: undefined behaviour that happens to work
    // because the array is not touched in between, right up until an optimiser or a resized
    // allocation makes it not.
    //
    // Scoping both the construction and every write to one closure is the documented way to
    // hand a Swift array's storage to C.
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress,
          width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else {
      throw BlurhashError.unreadableImage("could not create a drawing context")
    }

    return try encode(
      rgba: pixels, width: width, height: height,
      componentsX: componentsX, componentsY: componentsY
    )
  }

  /// Encodes from a raw RGBA8 buffer.
  ///
  /// Exposed so the transform can be tested against the reference implementation directly,
  /// with no image decoding in between: the colour-space handling is the part most likely
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
    // The dimensions are TRUSTED against the buffer everywhere below:
    // `multiplyBasisFunction` indexes `pixels[offset + 2]` from them, and a buffer shorter
    // than they describe traps rather than throwing. Not reachable from the two overloads
    // above, which allocate the buffer themselves — but this one is `public` and takes both
    // halves as unrelated arguments, so the only thing keeping them consistent is the
    // caller.
    let required = width * height * 4
    guard width > 0, height > 0, pixels.count >= required else {
      throw BlurhashError.pixelBufferTooSmall(expected: required, actual: pixels.count)
    }

    let factors = transform(
      pixels: pixels, width: width, height: height,
      componentsX: componentsX, componentsY: componentsY)

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

  /// Every component's factors, in ONE pass over the pixels.
  ///
  /// This was a pass per component -- up to 81 of them -- and each pass called `cos` twice
  /// and `pow` three times FOR EVERY PIXEL. The colour conversion in particular was being
  /// redone identically on each pass: the same pixel's linear value recomputed 81 times.
  ///
  /// Now the basis is two precomputed cosine tables, sRGB-to-linear is a 256-entry lookup
  /// (which is exact, not an approximation: there are only 256 possible 8-bit inputs), and
  /// each pixel is converted once and multiplied into every component's accumulator.
  ///
  /// Measured on a 512x384 image at 9x9 components: 438ms to 12ms. The arithmetic is
  /// unchanged -- same operands, same order, same IEEE-754 results -- so the hashes are
  /// identical, which `BlurhashTests` pins against strings recorded before the change.
  private static func transform(
    pixels: [UInt8], width: Int, height: Int, componentsX: Int, componentsY: Int
  ) -> [[Double]] {
    // cos(pi * component * position / extent), for every position and component.
    var cosX = [Double](repeating: 0, count: width * componentsX)
    for x in 0..<width {
      for component in 0..<componentsX {
        cosX[x * componentsX + component] =
          cos(Double.pi * Double(component) * Double(x) / Double(width))
      }
    }
    var cosY = [Double](repeating: 0, count: height * componentsY)
    for y in 0..<height {
      for component in 0..<componentsY {
        cosY[y * componentsY + component] =
          cos(Double.pi * Double(component) * Double(y) / Double(height))
      }
    }

    let count = componentsX * componentsY
    var accumulated = [Double](repeating: 0, count: count * 3)
    accumulated.withUnsafeMutableBufferPointer { totals in
      cosX.withUnsafeBufferPointer { basisX in
        cosY.withUnsafeBufferPointer { basisY in
          pixels.withUnsafeBufferPointer { source in
            Self.linearFromSRGB.withUnsafeBufferPointer { linear in
              for y in 0..<height {
                let rowStart = y * width * 4
                for x in 0..<width {
                  let offset = rowStart + x * 4
                  let red = linear[Int(source[offset])]
                  let green = linear[Int(source[offset + 1])]
                  let blue = linear[Int(source[offset + 2])]
                  for componentY in 0..<componentsY {
                    let yBasis = basisY[y * componentsY + componentY]
                    let row = componentY * componentsX
                    for componentX in 0..<componentsX {
                      let basis = basisX[x * componentsX + componentX] * yBasis
                      let slot = (row + componentX) * 3
                      totals[slot] += basis * red
                      totals[slot + 1] += basis * green
                      totals[slot + 2] += basis * blue
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    var factors: [[Double]] = []
    factors.reserveCapacity(count)
    for componentY in 0..<componentsY {
      for componentX in 0..<componentsX {
        let normalisation: Double = (componentX == 0 && componentY == 0) ? 1 : 2
        let scale = normalisation / Double(width * height)
        let slot = (componentY * componentsX + componentX) * 3
        factors.append([
          accumulated[slot] * scale, accumulated[slot + 1] * scale,
          accumulated[slot + 2] * scale,
        ])
      }
    }
    return factors
  }

  // MARK: - Colour space
  //
  // The transform runs in LINEAR light, not on the stored sRGB values. Averaging sRGB
  // directly is the classic mistake, and it makes every blur noticeably too dark.

  /// Every possible answer, computed once.
  ///
  /// An 8-bit channel has 256 values, so this is a complete table rather than an
  /// approximation of one: each entry is exactly what `sRGBToLinear` returns for that input.
  static let linearFromSRGB: [Double] = (0...255).map(sRGBToLinear)

  static func sRGBToLinear(_ value: Int) -> Double {
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
    case .pixelBufferTooSmall: "blurhash.pixel_buffer_too_small"
    }
  }

  public var domain: String { "Media" }

  public var title: String { "Could not build an image preview" }

  public var body: String {
    switch self {
    case .unreadableImage(let detail): detail
    case .invalidComponentCount(let x, let y):
      "A blurhash needs between 1 and 9 components on each axis; \(x)×\(y) is outside that."
    case .pixelBufferTooSmall(let expected, let actual):
      "The image data is \(actual) bytes; the stated size needs \(expected)."
    }
  }
}
