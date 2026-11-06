//  ZipArchiveSafetyTests
//  An archive is judged by the names it declares before anything is extracted.
//
//  The check used to walk the destination AFTER extraction, which can only see what landed
//  inside it: a member written outside was out of its reach by construction, so the
//  property it claimed rested entirely on `ditto` declining to do it. These archives are
//  made by hand, byte by byte, because they are exactly what no tool here would write.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BBExport

@Suite("ZIP member safety")
struct ZipArchiveSafetyTests {

  /// One entry of a hand-made archive.
  private struct Entry {
    var name: String
    var contents = Data("fine".utf8)
    /// The Unix mode in the external attributes; a symbolic link is `0o120777`.
    var mode: UInt32 = 0o100644
    /// The name the local header gives, when it should disagree with the central one.
    var localName: String?
  }

  @Test("A name that climbs out of the destination is refused before extraction")
  func parentTraversalIsRefused() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("climb.zip")
    try zip([Entry(name: "export.json"), Entry(name: "../escape.txt")]).write(to: archive)
    let destination = root.appendingPathComponent("inner/destination", isDirectory: true)

    await #expect(throws: ZipArchive.Failure.unsafeMember("../escape.txt")) {
      try await ZipArchive.extract(archive, into: destination)
    }
    // Refused BEFORE `ditto` ran: nothing was extracted anywhere, inside or out.
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appendingPathComponent("inner/escape.txt").path))
  }

  @Test("An absolute name, a backslash and an empty name are each refused")
  func otherUnsafeNamesAreRefused() throws {
    for name in ["/etc/thing", "..\\escape.txt", "folder/../../escape.txt", ""] {
      #expect(throws: ZipArchive.Failure.unsafeMember(name)) {
        _ = try ZipMembers.names(in: [UInt8](try zip([Entry(name: name)])))
      }
    }
  }

  /// A link extracted first and written through second is how an archive with only
  /// innocent-looking names reaches outside.
  @Test("A symbolic link member is refused")
  func symbolicLinksAreRefused() throws {
    let link = Entry(name: "link", contents: Data("../../outside".utf8), mode: 0o120777)
    #expect(throws: ZipArchive.Failure.unsafeMember("link")) {
      _ = try ZipMembers.names(in: [UInt8](try zip([link, Entry(name: "link/pwned.txt")])))
    }
  }

  /// The central directory is what this check reads; the local header is what a streaming
  /// reader writes to. A member that says one thing in each is listed as safe and
  /// extracted as something else.
  @Test("A member whose two headers disagree about its name is refused")
  func mismatchedLocalNameIsRefused() throws {
    let lying = Entry(name: "settings.json", localName: "../settings.json")
    #expect(throws: ZipArchive.Failure.unsafeMember("settings.json")) {
      _ = try ZipMembers.names(in: [UInt8](try zip([lying])))
    }
  }

  @Test("Something that is not a ZIP is refused as unreadable, not as unsafe")
  func notAZipIsUnreadable() {
    do {
      _ = try ZipMembers.names(in: [UInt8](Data("not an archive at all".utf8)))
      Issue.record("something that is not a ZIP was listed")
    } catch let failure as ZipArchive.Failure {
      guard case .extractFailed = failure else {
        Issue.record("refused as \(failure), not as unreadable")
        return
      }
    } catch {
      Issue.record("refused with \(error)")
    }
  }

  /// The other direction: a check that refuses an ordinary archive is an import that
  /// cannot be used, and looks exactly like a broken file.
  @Test("An ordinary archive, by hand or by ditto, is listed and extracts")
  func ordinaryArchivesPass() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }

    let handMade = root.appendingPathComponent("hand.zip")
    try zip([Entry(name: "export.json"), Entry(name: "folder/settings.json")])
      .write(to: handMade)
    #expect(
      try ZipMembers.read(handMade) == ["export.json", "folder/settings.json"])
    let extracted = root.appendingPathComponent("hand", isDirectory: true)
    try await ZipArchive.extract(handMade, into: extracted)
    #expect(
      FileManager.default.fileExists(
        atPath: extracted.appendingPathComponent("folder/settings.json").path))

    let source = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: source.appendingPathComponent("export.json"))
    let made = root.appendingPathComponent("ditto.zip")
    try await ZipArchive.create(contentsOf: source, into: made)
    #expect(try ZipMembers.read(made) == ["export.json"])
  }

  // MARK: Making archives by hand

  private func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-zip-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// A stored (uncompressed) ZIP, every field written out, so a test can say exactly what
  /// an archive declares.
  private func zip(_ entries: [Entry]) throws -> Data {
    var body = Data()
    var directory = Data()
    for entry in entries {
      let name = Data(entry.name.utf8)
      let localName = Data((entry.localName ?? entry.name).utf8)
      let crc = crc32(entry.contents)
      let size = UInt32(entry.contents.count)
      let offset = UInt32(body.count)

      body.append(le32(0x0403_4b50))
      body.append(le16(20))  // version needed
      body.append(le16(0))  // flags
      body.append(le16(0))  // stored
      body.append(le32(0))  // time and date
      body.append(le32(crc))
      body.append(le32(size))
      body.append(le32(size))
      body.append(le16(UInt16(localName.count)))
      body.append(le16(0))  // extra
      body.append(localName)
      body.append(entry.contents)

      directory.append(le32(0x0201_4b50))
      directory.append(le16(3 << 8 | 20))  // made by Unix
      directory.append(le16(20))
      directory.append(le16(0))
      directory.append(le16(0))
      directory.append(le32(0))
      directory.append(le32(crc))
      directory.append(le32(size))
      directory.append(le32(size))
      directory.append(le16(UInt16(name.count)))
      directory.append(le16(0))  // extra
      directory.append(le16(0))  // comment
      directory.append(le16(0))  // disk
      directory.append(le16(0))  // internal attributes
      directory.append(le32(entry.mode << 16))
      directory.append(le32(offset))
      directory.append(name)
    }
    var archive = body
    archive.append(directory)
    archive.append(le32(0x0605_4b50))
    archive.append(le16(0))
    archive.append(le16(0))
    archive.append(le16(UInt16(entries.count)))
    archive.append(le16(UInt16(entries.count)))
    archive.append(le32(UInt32(directory.count)))
    archive.append(le32(UInt32(body.count)))
    archive.append(le16(0))
    return archive
  }

  private func le16(_ value: UInt16) -> Data {
    Data([UInt8(value & 0xFF), UInt8(value >> 8)])
  }

  private func le32(_ value: UInt32) -> Data {
    Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) })
  }

  /// The ZIP checksum, bit by bit: slow, and a few bytes of fixture is all it ever sees.
  private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
      }
    }
    return ~crc
  }
}
