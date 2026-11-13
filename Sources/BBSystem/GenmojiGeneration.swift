//  GenmojiGeneration
//  Making a Genmoji for a program, through Apple's Image Playground.
//
//  A Genmoji is an image Apple Intelligence draws from a description. Two ways to ask for
//  one, both in this server's own process, neither needing the helper or the Private API:
//
//    - **The creator**, `ImagePlayground.ImageCreator` with the `.emoji` style: public,
//      headless, no window. The method on macOS 15.4 through 26. Below 15.4 there is nothing
//      to call; on Sonoma the framework does not exist at all.
//    - **The sheet**, `ImagePlaygroundViewController` in a window nobody sees, for macOS 27.
//      There `ImageCreator()` throws `notSupported` at once, logging "ImageCreator is
//      deprecated and no longer available for this application", for a bare binary, a signed
//      app bundle, a binary stamped with the 15.4 or 26.0 SDK, and a probe injected into
//      Messages.app itself: Apple withdrew the creator and left the sheet. The sheet needs a
//      running AppKit event loop, so it works inside the BlueBubbles app and not from the
//      headless CLI. `GenmojiSheet.swift` says how it is driven.
//
//  The sheet is a FALLBACK chosen by the creator's refusal on 27, never by the release alone,
//  so a release that re-allows the creator goes back to the public, windowless path by itself.
//  The same `notSupported` means "this Mac is not eligible" on 15 and 26, and the sheet is not
//  tried there: it runs the same model, and the measurement it rests on is 27's.
//
//  Everything that decides is a pure function over (release, creator outcome, sheet host), so
//  a test can hold the sentence for every combination on whatever Mac runs the suite. Only the
//  probes themselves, and the generation, touch ImagePlayground.
//
//  Unverified, and said so: whether a server running in the BACKGROUND is allowed to
//  generate on 15.4 through 26. `ImageCreator.Error.backgroundCreationForbidden` exists, and
//  the development Mac (27) cannot exercise the path. The error is mapped to a sentence
//  rather than hidden so a report from such a Mac says exactly what happened.

import BBCore
import CoreGraphics
import Foundation
import ImageIO
import ImagePlayground
import UniformTypeIdentifiers

// MARK: - Can this Mac?

/// How a Genmoji is made on this Mac, when one can be.
public enum GenmojiMethod: String, Sendable, Equatable {
  /// The headless creator: macOS 15.4 through 26.
  case imageCreator = "image_creator"
  /// The Image Playground sheet in a hidden window: macOS 27, inside the BlueBubbles app.
  case playgroundSheet = "playground_sheet"
}

/// Whether this Mac can generate a Genmoji for a program, and when it cannot, why.
public enum GenmojiSupport: Sendable, Equatable {
  case available(GenmojiMethod)
  /// Below macOS 15.4, where `ImageCreator` does not exist.
  case releaseTooOld(major: Int, minor: Int)
  /// macOS 27 and newer, where the creator is withdrawn and the sheet could not be driven.
  case withdrawn
  /// macOS 27 and newer from a process with no AppKit event loop: the headless server. The
  /// sheet that replaces the creator needs the BlueBubbles app.
  case needsApp
  /// Apple Intelligence is off, or its model has not finished downloading.
  case appleIntelligenceUnavailable
  /// Image Playground does not run on this Mac at all: Intel, or an unsupported region.
  case deviceNotEligible
  /// The system language is one Image Playground does not take descriptions in.
  case unsupportedLanguage
  /// Image Playground could not be asked, with the reason it gave.
  case undetermined(String)

  /// The release `ImageCreator` arrived in. Measured against the SDK's own availability.
  public static let minimumRelease = (major: 15, minor: 4)
  /// The release that refuses every application. Measured on 27.0.1; see the file header.
  public static let withdrawnFrom = 27

  public var isAvailable: Bool { method != nil }

  /// How generation would be done, when it can be.
  public var method: GenmojiMethod? {
    if case .available(let method) = self { return method }
    return nil
  }

  /// A stable word for the wire, so a client can branch without parsing the sentence.
  public var reason: String {
    switch self {
    case .available: "available"
    case .releaseTooOld: "release_too_old"
    case .withdrawn: "withdrawn"
    case .needsApp: "needs_app"
    case .appleIntelligenceUnavailable: "apple_intelligence_unavailable"
    case .deviceNotEligible: "device_not_eligible"
    case .unsupportedLanguage: "unsupported_language"
    case .undetermined: "undetermined"
    }
  }

  /// Why not, as a sentence a person can act on. Nil when generation is available.
  public var refusal: String? {
    switch self {
    case .available:
      nil
    case .releaseTooOld(let major, let minor):
      "Genmoji generation needs macOS Sequoia 15.4 or newer, and this Mac runs macOS "
        + "\(major).\(minor)"
    case .withdrawn:
      "macOS \(Self.withdrawnFrom) withdrew the Image Playground creation API, and the Image "
        + "Playground sheet this server uses in its place could not be driven on this Mac"
    case .needsApp:
      "On macOS \(Self.withdrawnFrom) a Genmoji is made through the Image Playground sheet, "
        + "which needs the BlueBubbles app: this server is running without it. Start the "
        + "server from the BlueBubbles app instead"
    case .appleIntelligenceUnavailable:
      "Apple Intelligence is not ready on this Mac: turn it on in System Settings and wait "
        + "for its model to finish downloading"
    case .deviceNotEligible:
      "Image Playground is not supported on this Mac: Apple Intelligence needs Apple silicon "
        + "and a supported region"
    case .unsupportedLanguage:
      "Image Playground does not take descriptions in this Mac's language"
    case .undetermined(let detail):
      "Image Playground could not be reached: \(detail)"
    }
  }

  /// The decision, from the release, from what Image Playground answered when asked for a
  /// creator, and, on 27 and newer only, from whether this process can host the sheet.
  ///
  /// `probe` is nil when the creator was not asked, which is the right answer below the floor
  /// and the wrong one above it. `sheet` is read only when the creator refused on 27 or newer;
  /// nil there means it was not asked, which is reported rather than guessed.
  public static func decide(
    majorVersion: Int, minorVersion: Int, probe: GenmojiProbeOutcome?,
    sheet: GenmojiSheetHost? = nil
  ) -> GenmojiSupport {
    if majorVersion < minimumRelease.major
      || (majorVersion == minimumRelease.major && minorVersion < minimumRelease.minor)
    {
      return .releaseTooOld(major: majorVersion, minor: minorVersion)
    }
    guard let probe else { return .undetermined("Image Playground was not asked") }
    switch probe {
    case .ready: return .available(.imageCreator)
    // The same refusal, two meanings: see the file header for the measurement behind the
    // split. Below 27 it is the Mac, and the sheet would refuse too.
    case .notSupported:
      guard majorVersion >= withdrawnFrom else { return .deviceNotEligible }
      switch sheet {
      case .ready: return .available(.playgroundSheet)
      case .noEventLoop: return .needsApp
      case .imagePlaygroundUnavailable: return .appleIntelligenceUnavailable
      case .broken: return .withdrawn
      case nil: return .undetermined("the Image Playground sheet was not asked")
      }
    case .unavailable: return .appleIntelligenceUnavailable
    case .unsupportedLanguage: return .unsupportedLanguage
    case .failed(let detail): return .undetermined(detail)
    }
  }
}

/// What `ImageCreator()` answered, as a value with no ImagePlayground type in it, so the
/// decision above can be tested on a Mac that cannot run the probe.
public enum GenmojiProbeOutcome: Sendable, Equatable {
  case ready
  case notSupported
  case unavailable
  case unsupportedLanguage
  case failed(String)
}

// MARK: - Generating

/// One generated Genmoji: a PNG with transparency, as the client will show and send it.
public struct GeneratedGenmoji: Sendable, Equatable {
  public let png: Data
  public let width: Int
  public let height: Int

  public init(png: Data, width: Int, height: Int) {
    self.png = png
    self.width = width
    self.height = height
  }
}

/// Something that can say whether this Mac generates Genmoji, and generate them.
///
/// A protocol so the interface above it can be tested with a scripted generator on a Mac
/// whose own answer is "no", which the development Mac's is.
public protocol GenmojiGenerating: Sendable {
  func support() async -> GenmojiSupport
  /// Up to `limit` images for `description`. Throws `GenmojiGenerationError`.
  func generate(description: String, limit: Int) async throws -> [GeneratedGenmoji]
}

public enum GenmojiGenerationError: Error, Equatable {
  case unsupported(GenmojiSupport)
  case creationFailed(String)
  /// The sheet never answered: how a description Image Playground declines shows itself.
  case noAnswer(String)
  case noImage
  case encodingFailed
}

extension GenmojiGenerationError: BBError {
  public var domain: String { "Genmoji" }

  public var title: String { "Could not generate a Genmoji" }

  public var code: String {
    switch self {
    case .unsupported: "genmoji.unsupported"
    case .creationFailed: "genmoji.creation_failed"
    case .noAnswer: "genmoji.no_answer"
    case .noImage: "genmoji.no_image"
    case .encodingFailed: "genmoji.encoding_failed"
    }
  }

  /// The stable word a client branches on, as `data.reason` beside the sentence.
  public var reason: String {
    switch self {
    case .unsupported(let support): support.reason
    case .creationFailed: "creation_failed"
    case .noAnswer: "no_answer"
    case .noImage: "no_image"
    case .encodingFailed: "encoding_failed"
    }
  }

  public var body: String {
    switch self {
    case .unsupported(let support):
      support.refusal ?? "Genmoji generation is not available on this Mac"
    case .creationFailed(let reason), .noAnswer(let reason): reason
    case .noImage: "Image Playground finished without producing an image"
    case .encodingFailed: "The generated image could not be encoded as PNG"
    }
  }
}

/// The real thing: the creator where Image Playground allows it, the sheet on macOS 27.
public struct ImagePlaygroundGenmojiGenerator: GenmojiGenerating {

  let majorVersion: Int
  let minorVersion: Int

  /// The one place the host's version is read; everything else takes it as a parameter.
  public init(
    operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
  ) {
    majorVersion = operatingSystemVersion.majorVersion
    minorVersion = operatingSystemVersion.minorVersion
  }

  public func support() async -> GenmojiSupport {
    // Decided without asking where asking is impossible: below the floor the framework may
    // not even be on disk.
    let early = GenmojiSupport.decide(
      majorVersion: majorVersion, minorVersion: minorVersion, probe: nil)
    if case .releaseTooOld = early { return early }
    guard #available(macOS 15.4, *) else {
      return .releaseTooOld(major: majorVersion, minor: minorVersion)
    }
    switch await Self.creator() {
    case .ready:
      return .available(.imageCreator)
    case .refused(let outcome):
      return await decide(refused: outcome)
    }
  }

  public func generate(description: String, limit: Int) async throws -> [GeneratedGenmoji] {
    guard #available(macOS 15.4, *) else {
      throw GenmojiGenerationError.unsupported(
        .releaseTooOld(major: majorVersion, minor: minorVersion))
    }
    switch await Self.creator() {
    case .ready(let creator):
      return try await Self.images(from: creator, description: description, limit: limit)
    case .refused(let outcome):
      let support = await decide(refused: outcome)
      guard support.method == .playgroundSheet else {
        throw GenmojiGenerationError.unsupported(support)
      }
      return try await Self.sheetImages(description: description, limit: limit)
    }
  }

  /// The decision once the creator has refused, asking the sheet host only where the
  /// decision reads it: on 27 and newer, for `notSupported`.
  @available(macOS 15.4, *)
  private func decide(refused outcome: GenmojiProbeOutcome) async -> GenmojiSupport {
    let sheet: GenmojiSheetHost? =
      outcome == .notSupported && majorVersion >= GenmojiSupport.withdrawnFrom
      ? await PlaygroundSheet.host() : nil
    return GenmojiSupport.decide(
      majorVersion: majorVersion, minorVersion: minorVersion, probe: outcome, sheet: sheet)
  }

  @available(macOS 15.4, *)
  private static func images(
    from creator: ImageCreator, description: String, limit: Int
  ) async throws -> [GeneratedGenmoji] {
    var images: [GeneratedGenmoji] = []
    do {
      // Encoded inside the loop so nothing but `Data` outlives the iteration.
      for try await created in creator.images(
        for: [.text(description)], style: .emoji, limit: limit)
      {
        images.append(try Self.png(created.cgImage))
      }
    } catch let error as ImageCreator.Error {
      throw GenmojiGenerationError.creationFailed(Self.sentence(for: error))
    } catch let error as GenmojiGenerationError {
      throw error
    } catch {
      throw GenmojiGenerationError.creationFailed(
        "Image Playground failed: \(DiagnosticText.sentence(for: error))")
    }
    guard !images.isEmpty else { throw GenmojiGenerationError.noImage }
    return images
  }

  /// One sheet session per image, one after another: a sheet confirms one Genmoji, so
  /// `limit` variations are `limit` sessions of about seven seconds each.
  @available(macOS 15.4, *)
  private static func sheetImages(description: String, limit: Int) async throws
    -> [GeneratedGenmoji]
  {
    var images: [GeneratedGenmoji] = []
    for _ in 0..<limit {
      switch try await PlaygroundSheet.generate(description: description) {
      case .glyph(let heic): images.append(try largestStrike(of: heic))
      case .image(let data): images.append(try largestStrike(of: data))
      case .cancelled:
        throw GenmojiGenerationError.creationFailed("Image Playground cancelled the Genmoji")
      }
    }
    guard !images.isEmpty else { throw GenmojiGenerationError.noImage }
    return images
  }

  /// The biggest image in a file, as PNG.
  ///
  /// A Genmoji's glyph is a HEIC holding one image per strike (40 to 320 pixels on 27.0.1,
  /// measured), so the largest is the one a client shows and sends as a sticker. A plain
  /// image file has one, which this takes too.
  static func largestStrike(of file: Data) throws -> GeneratedGenmoji {
    guard let source = CGImageSourceCreateWithData(file as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { throw GenmojiGenerationError.noImage }
    let widths = (0..<CGImageSourceGetCount(source)).map { index -> Int in
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
      return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    }
    let largest = widths.indices.max { widths[$0] < widths[$1] } ?? 0
    guard let image = CGImageSourceCreateImageAtIndex(source, largest, nil) else {
      throw GenmojiGenerationError.noImage
    }
    return try png(image)
  }

  /// A creator, or the probe outcome that stands in for one. Not a `Result`, because a
  /// refusal here is an answer about the Mac rather than an error, and a plain `Error` type
  /// under `Sources/` is refused by `ErrorTypePolicyTests` for good reason.
  @available(macOS 15.4, *)
  enum CreatorOutcome {
    case ready(ImageCreator)
    case refused(GenmojiProbeOutcome)
  }

  /// Asks Image Playground for a creator, which is also the capability probe: the
  /// initialiser is where every refusal is raised.
  @available(macOS 15.4, *)
  static func creator() async -> CreatorOutcome {
    do {
      return .ready(try await ImageCreator())
    } catch let error as ImageCreator.Error {
      switch error {
      case .notSupported: return .refused(.notSupported)
      case .unavailable: return .refused(.unavailable)
      case .unsupportedLanguage: return .refused(.unsupportedLanguage)
      default: return .refused(.failed(sentence(for: error)))
      }
    } catch {
      return .refused(.failed(DiagnosticText.sentence(for: error)))
    }
  }

  /// Image Playground's refusals, in words. The input-image cases cannot arise from a text
  /// description and are still named, so an unexpected one is reported rather than guessed at.
  @available(macOS 15.4, *)
  static func sentence(for error: ImageCreator.Error) -> String {
    switch error {
    case .notSupported: GenmojiSupport.deviceNotEligible.refusal ?? "not supported"
    case .unavailable: GenmojiSupport.appleIntelligenceUnavailable.refusal ?? "unavailable"
    case .unsupportedLanguage: GenmojiSupport.unsupportedLanguage.refusal ?? "unsupported language"
    case .creationCancelled: "Image Playground cancelled the request"
    case .backgroundCreationForbidden:
      "Image Playground refuses to create an image for an application that is not in the "
        + "foreground"
    case .faceInImageTooSmall, .unsupportedInputImage:
      "Image Playground refused the input image"
    case .creationFailed: "Image Playground could not create the image"
    default: "Image Playground refused: \(error)"
    }
  }

  /// PNG, because it is the one format with transparency every client decodes; the
  /// attachment path reaches the same conclusion in `AttachmentConversion`.
  static func png(_ image: CGImage) throws -> GeneratedGenmoji {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil)
    else { throw GenmojiGenerationError.encodingFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw GenmojiGenerationError.encodingFailed
    }
    return GeneratedGenmoji(png: data as Data, width: image.width, height: image.height)
  }
}
