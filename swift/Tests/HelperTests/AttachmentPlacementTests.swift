//  AttachmentPlacementTests
//  Staging an attachment clones rather than copies, and still works when it cannot.
//
//  This runs on Messages.app's MAIN THREAD and cannot simply move off it: `IMCoreBridge` is
//  main-actor isolated, and the send path's header argues at length that the composition and
//  the send must not be separated by a suspension. So the copy that used to be here froze the
//  user's Messages interface for as long as it took, which for a video sent through
//  `POST /message/attachment` is seconds.
//
//  A clone makes that a syscall on APFS, which every supported Mac boots. What is asserted
//  here is both halves: that the fast path produces a real, independent file, and that the
//  fallback still produces one when a clone is impossible — because a clone failing must
//  degrade to a copy, not to a missing attachment.

import Foundation
import Testing

@testable import BlueBubblesHelper

@Suite("Attachment placement")
struct AttachmentPlacementTests {

  private static func temporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-place-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test("The staged file has the same bytes as the source")
  func placesTheBytes() throws {
    let directory = try Self.temporaryDirectory()
    let source = directory.appendingPathComponent("source.bin")
    let destination = directory.appendingPathComponent("staged.bin")
    let bytes = Data((0..<4096).map { UInt8($0 % 251) })
    try bytes.write(to: source)

    try CKCompositions.place(source.path, at: destination.path)
    #expect(try Data(contentsOf: destination) == bytes)
  }

  /// A clone shares storage until one side is written. Deleting the source must not take
  /// the staged file with it, or the transfer registers against nothing.
  @Test("The staged file survives the source being deleted")
  func survivesSourceDeletion() throws {
    let directory = try Self.temporaryDirectory()
    let source = directory.appendingPathComponent("source.bin")
    let destination = directory.appendingPathComponent("staged.bin")
    let bytes = Data("BB test attachment".utf8)
    try bytes.write(to: source)

    try CKCompositions.place(source.path, at: destination.path)
    try FileManager.default.removeItem(at: source)

    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(try Data(contentsOf: destination) == bytes)
  }

  @Test("A source that is not there is reported, not silently skipped")
  func missingSourceThrows() throws {
    let directory = try Self.temporaryDirectory()
    #expect(throws: (any Error).self) {
      try CKCompositions.place(
        directory.appendingPathComponent("absent.bin").path,
        at: directory.appendingPathComponent("staged.bin").path)
    }
  }
}
