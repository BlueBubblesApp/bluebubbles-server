//  AttachmentStagingTests
//  The rules for copying an attachment into Messages' container before a send.
//
//  Scope, stated up front because the important half is not here. WHY staging exists (
//  Messages' sandbox refuses to read a file outside its own container, so a path the server
//  can open is one the send cannot) is observable only with a dylib injected into a running
//  Messages, and is recorded in `AttachmentStaging`'s own documentation rather than proven
//  by any test. What this file covers is everything downstream of that decision, all of which
//  can fail on its own: the filename survives the copy because it becomes the attachment's
//  name in the conversation, only the directory is made unique so two files called photo.jpg
//  do not collide, the original is left in place because a client may still be reading it, a
//  path already inside the container is passed through rather than copied twice, a missing
//  file is refused instead of staged empty, and the age sweep removes old copies without
//  taking live ones with it.
//
//  → `.claude/docs/private-api.md`

import Foundation
import Testing

@testable import BBPrivateAPI
@testable import BBPrivateAPIContract

@Suite("Attachment staging")
struct AttachmentStagingTests {

  private func makeFile(_ name: String, bytes: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(name).path
    try bytes.write(toFile: path, atomically: true, encoding: .utf8)
    return path
  }

  @Test("copies the file into Messages' container, keeping its name")
  func stagesIntoContainer() throws {
    let source = try makeFile("photo.jpg", bytes: "bytes")
    let staged = try AttachmentStaging.stage(source)
    defer { try? FileManager.default.removeItem(atPath: staged) }

    #expect(staged.hasPrefix(SocketLocation.messagesContainer + "/"))
    // The filename becomes the attachment's name in the conversation, so only the
    // directory may be made unique.
    #expect(URL(fileURLWithPath: staged).lastPathComponent == "photo.jpg")
    #expect(try String(contentsOfFile: staged, encoding: .utf8) == "bytes")
    // The original is left alone; a client may still be using it.
    #expect(FileManager.default.fileExists(atPath: source))
  }

  @Test("two files of the same name do not collide")
  func distinctDirectories() throws {
    let first = try AttachmentStaging.stage(try makeFile("photo.jpg", bytes: "one"))
    let second = try AttachmentStaging.stage(try makeFile("photo.jpg", bytes: "two"))
    defer {
      try? FileManager.default.removeItem(atPath: first)
      try? FileManager.default.removeItem(atPath: second)
    }
    #expect(first != second)
    #expect(try String(contentsOfFile: first, encoding: .utf8) == "one")
    #expect(try String(contentsOfFile: second, encoding: .utf8) == "two")
  }

  @Test("a file already inside the container is returned untouched")
  func passesThroughContainerPaths() throws {
    let inside = SocketLocation.messagesContainer + "/tmp/staging-test.txt"
    try FileManager.default.createDirectory(
      atPath: SocketLocation.messagesContainer + "/tmp",
      withIntermediateDirectories: true
    )
    try "already here".write(toFile: inside, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: inside) }

    #expect(try AttachmentStaging.stage(inside) == inside)
  }

  @Test("only attachment parts are staged")
  func stagesPartsSelectively() throws {
    let source = try makeFile("photo.jpg", bytes: "bytes")
    let parts = [
      MessagePart(text: "look at this"),
      MessagePart(attachmentPath: source),
      MessagePart(text: "@you", mention: "you"),
    ]
    let staged = try AttachmentStaging.stage(parts: parts)
    defer {
      for path in staged.compactMap(\.attachmentPath) {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    #expect(staged.count == 3)
    #expect(staged[0].text == "look at this")
    #expect(staged[0].attachmentPath == nil)
    #expect(staged[1].attachmentPath?.hasPrefix(SocketLocation.messagesContainer) == true)
    // Order and mentions decide where each part lands in the sent message.
    #expect(staged[2].mention == "you")
  }

  @Test("a missing file is refused rather than staged empty")
  func refusesMissingFile() {
    #expect(throws: PrivateAPIError.self) {
      _ = try AttachmentStaging.stage("/nonexistent/nope.jpg")
    }
  }

  @Test("the sweep removes aged copies and leaves fresh ones")
  func sweepsByAge() throws {
    let fresh = try AttachmentStaging.stage(try makeFile("fresh.jpg", bytes: "new"))
    let stale = try AttachmentStaging.stage(try makeFile("stale.jpg", bytes: "old"))
    let staleDirectory = URL(fileURLWithPath: stale).deletingLastPathComponent().path
    try FileManager.default.setAttributes(
      [.creationDate: Date().addingTimeInterval(-AttachmentStaging.maximumAge - 60)],
      ofItemAtPath: staleDirectory
    )
    defer { try? FileManager.default.removeItem(atPath: fresh) }

    AttachmentStaging.sweep()

    #expect(!FileManager.default.fileExists(atPath: stale))
    #expect(FileManager.default.fileExists(atPath: fresh))
  }
}
