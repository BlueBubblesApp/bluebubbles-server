//  GenmojiInterface
//  Generating a Genmoji on request, and saying beforehand whether this Mac can.
//
//  Two operations, and the second exists so a client never has to earn the first's refusal:
//  `support()` answers what `create` would say before any work is done, so a client can
//  hide the button rather than offer it and apologise. Both read the same decision, so the
//  two never disagree about this Mac.
//
//  Generation runs in THIS process through `ImagePlaygroundGenmojiGenerator` (`BBSystem`),
//  which is why this interface is not `MessagesBackedInterface` and needs no helper: it
//  reaches Messages for nothing. That generator uses Apple's headless creator on macOS 15.4
//  through 26 and the Image Playground sheet on 27, where the sheet needs the BlueBubbles
//  app; this interface does not know which, and `GenmojiSupport.method` says. What it hands back is a PNG the client shows the person,
//  and a path in the upload store so the same bytes can be sent without a second upload,
//  through `POST message/sticker` or `POST message/attachment`, exactly as an
//  `attachment/upload` answer is. Sending one INLINE, as the adaptive image glyph Messages
//  itself sends from the picker, is not done here; `TODO.md` records what it would take.
//
//  Every refusal is a 400, and it says why twice: a sentence for the person in `error.message`
//  and a stable word for the client in `data.reason` (`InterfaceError.declined`). One status
//  for all of them, because the two a 5xx would have been used for are what clients and
//  proxies already read 5xx as: a tunnel answers 503 when the SERVER is unreachable, and
//  retry policies retry a 503 by default, which here would run a model again unasked. The
//  input checks (an empty or over-long description, a count out of range) are ordinary
//  `invalidRequest`s with no `reason`, because they are this route's own rules. The one
//  answer that is not a 400 is this server's own fault, an image it could not encode, which
//  is the generic 500 every unexpected failure is.
//
//  A re-prompt is a new request. Messages' own "ask for changes" runs inside Apple's remote
//  extension and was measured not to answer a second concept from the host, so a client
//  revises by sending the amended description again, and asks for `count` variations to
//  offer a choice.

import BBCore
import BBMedia
import BBSystem
import Foundation

public struct GenmojiInterface: Sendable {

  /// What a client asked for, typed. Never a raw body: see `BBInterfaces/CLAUDE.md`.
  public struct CreateRequest: Sendable, Equatable {
    /// What the Genmoji should show, in words.
    public let description: String
    /// How many variations to draw, 1 to `maximumCount`.
    public let count: Int

    public init(description: String, count: Int = 1) {
      self.description = description
      self.count = count
    }
  }

  /// One generated image, where it was staged.
  public struct StagedGenmoji: Sendable, Equatable {
    public let image: GeneratedGenmoji
    /// The upload store's client form (`<uuid>/<file>`), which the send routes' `filePath`
    /// resolves. See `UploadStore.clientPath(of:)`.
    public let filePath: String
  }

  public struct Created: Sendable, Equatable {
    public let description: String
    public let images: [StagedGenmoji]
  }

  /// The most variations one request may ask for. Each one is a full model run, measured in
  /// seconds, and the route's timeout is sized for this many.
  public static let maximumCount = 4

  /// The longest description accepted, in characters, after trimming.
  ///
  /// Not Apple's limit: a 1500-character description generated normally on 27.0.1, and Image
  /// Playground condensed it to four words for the glyph's own name. This bounds what one
  /// request may ask the model to read, at several times anything a Genmoji needs.
  public static let maximumDescriptionLength = 500

  let generator: any GenmojiGenerating
  let uploads: UploadStore

  public init(generator: any GenmojiGenerating, uploads: UploadStore) {
    self.generator = generator
    self.uploads = uploads
  }

  /// Whether `create` would succeed on this Mac, and if not, why.
  public func support() async -> GenmojiSupport {
    await generator.support()
  }

  /// Throws the refusal `create` would throw, so a caller can check first.
  public func requireSupported() async throws {
    try Self.check(await support())
  }

  /// `requireSupported`, with the answer given, so each refusal can be tested on any Mac.
  static func check(_ support: GenmojiSupport) throws {
    guard let refusal = support.refusal else { return }
    throw InterfaceError.declined(refusal, reason: support.reason)
  }

  /// Generates `request.count` Genmoji for `request.description` and stages each as a PNG.
  public func create(_ request: CreateRequest) async throws -> Created {
    let description = request.description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !description.isEmpty else {
      throw InterfaceError.invalidRequest(
        "`description` is required: say what the Genmoji should show")
    }
    guard description.count <= Self.maximumDescriptionLength else {
      throw InterfaceError.invalidRequest(
        "`description` must be at most \(Self.maximumDescriptionLength) characters")
    }
    guard (1...Self.maximumCount).contains(request.count) else {
      throw InterfaceError.invalidRequest(
        "`count` must be between 1 and \(Self.maximumCount)")
    }
    try await requireSupported()

    let images: [GeneratedGenmoji]
    do {
      images = try await generator.generate(description: description, limit: request.count)
    } catch let error as GenmojiGenerationError {
      switch error {
      case .unsupported(let support):
        // The capability moved between the check and the call; answer as the check would.
        try Self.check(support)
        throw InterfaceError.declined(error.body, reason: error.reason)
      case .creationFailed, .noAnswer, .noImage:
        throw InterfaceError.declined(error.body, reason: error.reason)
      case .encodingFailed:
        // This server's fault, not the request's: the generic 500.
        throw error
      }
    }

    var staged: [StagedGenmoji] = []
    for (index, image) in images.enumerated() {
      let path = try uploads.stage(image.png, named: "genmoji-\(index + 1).png")
      staged.append(StagedGenmoji(image: image, filePath: uploads.clientPath(of: path)))
    }
    return Created(description: description, images: staged)
  }
}
