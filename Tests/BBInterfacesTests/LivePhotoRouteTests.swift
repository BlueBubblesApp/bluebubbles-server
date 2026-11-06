//  LivePhotoRouteTests
//  `GET /attachment/:guid/live` serves exactly the video `hasLivePhoto` reported.
//
//  The reference's route and serializer both ask `getLivePhotoPath`, so the flag and the
//  route cannot disagree there. Here they were derived twice and did: the route dropped one
//  extension and probed `.mov` beside anything, so a converted `.heic.jpeg` still was flagged
//  `true` and answered 404, and a PDF with a `.mov` beside it was flagged `false` and served
//  the video. Each case below asserts the route against the flag on the same attachment.

import BBCore
import BBSerialization
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Live Photo route")
struct LivePhotoRouteTests {

  /// A still and, beside it, the files named; the interface over a one-row database
  /// pointing at the still.
  private func attachment(
    still: String, beside: [String], in directory: URL
  ) throws -> AttachmentInterface {
    let path = directory.appendingPathComponent(still)
    try Data("BB test".utf8).write(to: path)
    for name in beside {
      try Data("BB test".utf8).write(to: directory.appendingPathComponent(name))
    }
    return AttachmentInterface(
      repository: try InterfaceFixtures.attachment(guid: "attachment-1", filename: path.path))
  }

  /// What the route answers: the video's file name, or nil for the reference's 404.
  private func served(_ interface: AttachmentInterface) async throws -> String? {
    do {
      return (try await interface.livePhotoPath(guid: "attachment-1") as NSString)
        .lastPathComponent
    } catch let error as InterfaceError {
      #expect(error == .notFound(ReferenceMessages.livePhotoNotFound))
      return nil
    }
  }

  /// What the serializer reports for the same attachment.
  private func flagged(_ interface: AttachmentInterface) async throws -> Bool? {
    let row = try #require(try await interface.find(guid: "attachment-1"))
    return await interface.serialize(row)["hasLivePhoto"]?.boolValue
  }

  @Test(
    "The route serves a video exactly when the flag says there is one",
    arguments: [
      // The converted still: flagged true, and the route probed `IMG.heic.mov`.
      ("IMG.heic.jpeg", ["IMG.mov"], "IMG.mov"),
      // Not an image: no Live Photo, though a `.mov` of the same name sits beside it.
      ("doc.pdf", ["doc.mov"], nil),
      // The ordinary pair, in both spellings Messages writes.
      ("IMG.HEIC", ["IMG.MOV"], "IMG.MOV"),
      ("IMG.jpeg", ["IMG.mov"], "IMG.mov"),
      // A still with no video at all.
      ("IMG.png", [], nil),
    ] as [(String, [String], String?)])
  func routeMatchesFlag(still: String, beside: [String], expected: String?) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-live-route-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let interface = try attachment(still: still, beside: beside, in: directory)
    // Compared without case: on a case-insensitive volume `IMG.mov`, the first spelling
    // probed, already finds an `IMG.MOV`.
    #expect(try await served(interface)?.lowercased() == expected?.lowercased())
    #expect(try await flagged(interface) == (expected != nil))
  }
}
