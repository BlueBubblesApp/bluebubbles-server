//  GenmojiInterfaceTests
//  What a client gets from the Genmoji interface, over a scripted generator.
//
//  The development Mac refuses every generation, so the success path only ever runs here,
//  against a generator that answers what a 15.4 through 26 Mac would. What is held: the
//  refusals keep their status, the inputs are checked before Image Playground is asked, and
//  a generated image comes back both as bytes and as a path the send routes resolve.

import BBMedia
import BBSystem
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Genmoji interface")
struct GenmojiInterfaceTests {

  /// A generator that answers what it is told to, and counts how often it was asked.
  final class Scripted: GenmojiGenerating, @unchecked Sendable {
    var answer: GenmojiSupport
    var images: [GeneratedGenmoji]
    var failure: GenmojiGenerationError?
    private(set) var generateCalls = 0

    init(answer: GenmojiSupport, images: [GeneratedGenmoji] = []) {
      self.answer = answer
      self.images = images
    }

    func support() async -> GenmojiSupport { answer }

    func generate(description: String, limit: Int) async throws -> [GeneratedGenmoji] {
      generateCalls += 1
      if let failure { throw failure }
      return Array(images.prefix(limit))
    }
  }

  private func store() throws -> UploadStore {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("genmoji-tests-\(UUID().uuidString)")
    return UploadStore(directory: directory)
  }

  /// A one-pixel PNG: real bytes, so the staged file is a file.
  private static let pixel = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  )!

  @Test("Every refusal is a 400 carrying the sentence and the reason, never a 5xx")
  func refusalsAreDeclined() throws {
    let refused: [GenmojiSupport] = [
      .releaseTooOld(major: 14, minor: 6), .withdrawn, .needsApp, .deviceNotEligible,
      .unsupportedLanguage, .appleIntelligenceUnavailable, .undetermined("xpc"),
    ]
    for support in refused {
      do {
        try GenmojiInterface.check(support)
        Issue.record("\(support.reason) should refuse")
      } catch let error as InterfaceError {
        #expect(error == .declined(support.refusal ?? "", reason: support.reason))
      }
    }
    try GenmojiInterface.check(.available(.imageCreator))
    try GenmojiInterface.check(.available(.playgroundSheet))
  }

  @Test("An empty description or an out-of-range count is refused before Image Playground is asked")
  func inputsFirst() async throws {
    let generator = Scripted(
      answer: .available(.imageCreator), images: [.init(png: Self.pixel, width: 1, height: 1)])
    let interface = GenmojiInterface(generator: generator, uploads: try store())
    await #expect(throws: InterfaceError.self) {
      try await interface.create(.init(description: "   \n"))
    }
    await #expect(throws: InterfaceError.self) {
      try await interface.create(.init(description: "BB test", count: 0))
    }
    await #expect(throws: InterfaceError.self) {
      try await interface.create(
        .init(description: "BB test", count: GenmojiInterface.maximumCount + 1))
    }
    #expect(generator.generateCalls == 0)
  }

  @Test("A description over the ceiling is refused, and one at it is accepted")
  func descriptionCeiling() async throws {
    let generator = Scripted(
      answer: .available(.playgroundSheet), images: [.init(png: Self.pixel, width: 1, height: 1)])
    let interface = GenmojiInterface(generator: generator, uploads: try store())
    let limit = GenmojiInterface.maximumDescriptionLength
    await #expect(throws: InterfaceError.self) {
      try await interface.create(.init(description: String(repeating: "a", count: limit + 1)))
    }
    #expect(generator.generateCalls == 0)
    // Counted after trimming: padding around a description at the ceiling is not refused.
    _ = try await interface.create(
      .init(description: "  " + String(repeating: "a", count: limit) + "\n"))
    #expect(generator.generateCalls == 1)
  }

  @Test("The capability is checked before generating, with the same refusal the status route gives")
  func capabilityFirst() async throws {
    let generator = Scripted(
      answer: .withdrawn, images: [.init(png: Self.pixel, width: 1, height: 1)])
    let interface = GenmojiInterface(generator: generator, uploads: try store())
    await #expect(throws: InterfaceError.self) {
      try await interface.create(.init(description: "BB test"))
    }
    #expect(generator.generateCalls == 0)
    #expect(await interface.support() == .withdrawn)
  }

  @Test("A generated image is staged as a PNG the send routes resolve, and described trimmed")
  func stagesEachImage() async throws {
    let uploads = try store()
    let generator = Scripted(
      answer: .available(.imageCreator),
      images: [
        .init(png: Self.pixel, width: 1, height: 1), .init(png: Self.pixel, width: 1, height: 1),
      ])
    let interface = GenmojiInterface(generator: generator, uploads: uploads)
    let created = try await interface.create(.init(description: "  BB test cactus  ", count: 2))
    #expect(created.description == "BB test cactus")
    #expect(created.images.count == 2)
    for (index, staged) in created.images.enumerated() {
      // The client form, which `confined` resolves back to a file holding the same bytes.
      #expect(staged.filePath.hasSuffix("/genmoji-\(index + 1).png"))
      #expect(!staged.filePath.hasPrefix("/"))
      let resolved = try uploads.confined(staged.filePath)
      #expect(try Data(contentsOf: URL(fileURLWithPath: resolved)) == Self.pixel)
    }
    // Two images, two directories: a second request never overwrites the first's file.
    #expect(Set(created.images.map(\.filePath)).count == 2)
    #expect(generator.generateCalls == 1)
  }

  @Test(
    "A generation that fails after the check is declined with its own reason",
    arguments: [
      (
        GenmojiGenerationError.creationFailed("Image Playground cancelled the Genmoji"),
        "creation_failed"
      ),
      (GenmojiGenerationError.noAnswer("Image Playground did not make a Genmoji"), "no_answer"),
      (GenmojiGenerationError.noImage, "no_image"),
    ])
  func generationFailure(_ failure: GenmojiGenerationError, _ reason: String) async throws {
    let generator = Scripted(answer: .available(.playgroundSheet))
    generator.failure = failure
    let interface = GenmojiInterface(generator: generator, uploads: try store())
    do {
      _ = try await interface.create(.init(description: "BB test"))
      Issue.record("should have thrown")
    } catch let error as InterfaceError {
      #expect(error == .declined(failure.body, reason: reason))
    }
  }

  @Test("An image this server cannot encode is its own fault, not a declined request")
  func encodingFailureIsNotDeclined() async throws {
    let generator = Scripted(answer: .available(.imageCreator))
    generator.failure = .encodingFailed
    let interface = GenmojiInterface(generator: generator, uploads: try store())
    await #expect(throws: GenmojiGenerationError.encodingFailed) {
      try await interface.create(.init(description: "BB test"))
    }
  }

  @Test("The wire shapes carry the fields the OpenAPI document promises")
  func wireShapes() throws {
    let status = GenmojiInterface.serialize(GenmojiSupport.withdrawn)
    #expect(status["available"] == .bool(false))
    #expect(status["reason"] == .string("withdrawn"))
    #expect(status["detail"] == .string(GenmojiSupport.withdrawn.refusal!))
    #expect(status["method"] == .null)
    #expect(
      status["maximum_description_length"] == .int(GenmojiInterface.maximumDescriptionLength))
    let sheet = GenmojiInterface.serialize(GenmojiSupport.available(.playgroundSheet))
    #expect(sheet["detail"] == .null)
    #expect(sheet["method"] == .string("playground_sheet"))
    #expect(
      GenmojiInterface.serialize(GenmojiSupport.available(.imageCreator))["method"]
        == .string("image_creator"))

    let staged = GenmojiInterface.StagedGenmoji(
      image: .init(png: Self.pixel, width: 1, height: 1), filePath: "abc/genmoji-1.png")
    let json = GenmojiInterface.serialize(
      GenmojiInterface.Created(description: "BB test", images: [staged]))
    #expect(json["description"] == .string("BB test"))
    let image = json["images"]?.arrayValue?.first
    #expect(image?["file_path"] == .string("abc/genmoji-1.png"))
    #expect(image?["content_type"] == .string("image/png"))
    #expect(image?["byte_count"] == .int(Self.pixel.count))
    #expect(image?["data"] == .string(Self.pixel.base64EncodedString()))
  }
}
