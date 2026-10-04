//  ZipArchiveWriterTests
//  An archive this writer produces is one `unzip` can walk back.
//
//  Checked with the system's own `unzip -t`, which verifies every entry's CRC against its
//  bytes, rather than with a reader written here that would share the writer's mistakes.
//  The end-of-central-directory record is also read by hand, so the count of entries is
//  asserted against the bytes and not against the tool's wording.

import BBCore
import Foundation
import Testing

@testable import BBTranscript

@Suite("ZIP archive writer")
struct ZipArchiveWriterTests {

  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-zip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// The entry count out of the end-of-central-directory record, which is the last 22
  /// bytes of an archive without a comment.
  private func entryCount(of archive: URL) throws -> Int {
    let data = try Data(contentsOf: archive)
    let record = data.suffix(22)
    let signature = record.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    #expect(signature == 0x504b_0506, "the archive should end with an EOCD record")
    let count = record.dropFirst(10).prefix(2)
    return Int(count[count.startIndex]) | Int(count[count.startIndex + 1]) << 8
  }

  @Test("Deflated and stored entries both verify and read back")
  func roundTrip() throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let words = String(repeating: "the quick brown fox jumps over the lazy dog\n", count: 2000)
    let textFile = folder.appendingPathComponent("transcript.txt")
    try words.write(to: textFile, atomically: true, encoding: .utf8)
    // A linear congruential stream: not compressible, and the same bytes on every run.
    var noise = Data(count: 300_000)
    var state: UInt32 = 12345
    for index in 0..<noise.count {
      state = state &* 1_664_525 &+ 1_013_904_223
      noise[index] = UInt8(truncatingIfNeeded: state >> 24)
    }
    let noiseFile = folder.appendingPathComponent("photo.bin")
    try noise.write(to: noiseFile)

    let archive = folder.appendingPathComponent("out.zip")
    let zip = try ZipArchiveWriter(url: archive)
    try zip.add(fileAt: textFile, as: "transcript.txt", method: .deflate)
    try zip.add(fileAt: noiseFile, as: "attachments/ATT-1/photo.bin", method: .store)
    try zip.add(Data("{}".utf8), as: "manifest.json")
    try zip.add(Data(), as: "empty.txt")
    try zip.finish()

    #expect(try entryCount(of: archive) == 4)
    let size = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int
    // The text deflates to a fraction of itself; the noise is stored as is.
    #expect(try #require(size) < words.utf8.count / 4 + noise.count + 1024)

    let check = try Subprocess.runSynchronously(
      "/usr/bin/unzip", ["-t", archive.path], timeout: .seconds(30))
    #expect(check.succeeded, check.text)

    let extracted = try Subprocess.runSynchronously(
      "/usr/bin/unzip", ["-p", archive.path, "transcript.txt"], output: .standardOutputOnly,
      timeout: .seconds(30))
    #expect(extracted.text == words)
    let stored = try Subprocess.runSynchronously(
      "/usr/bin/unzip", ["-p", archive.path, "attachments/ATT-1/photo.bin"],
      output: .standardOutputOnly, timeout: .seconds(30))
    #expect(stored.output == noise)
  }

  @Test("Media is stored and text is deflated by default")
  func methodChoice() {
    #expect(ZipArchiveWriter.Method.suggested(forMIMEType: "image/heic") == .store)
    #expect(ZipArchiveWriter.Method.suggested(forMIMEType: "video/quicktime") == .store)
    #expect(ZipArchiveWriter.Method.suggested(forMIMEType: "application/zip") == .store)
    #expect(ZipArchiveWriter.Method.suggested(forMIMEType: "text/plain") == .deflate)
    #expect(ZipArchiveWriter.Method.suggested(forMIMEType: nil) == .deflate)
  }

  @Test("CRC-32 matches the published check value")
  func crc() {
    var crc = CRC32()
    crc.update(Data("123456789".utf8))
    #expect(crc.value == 0xCBF4_3926)
  }

  @Test("An unreadable source is refused rather than written as an empty entry")
  func missingFile() throws {
    let folder = try scratch()
    defer { try? FileManager.default.removeItem(at: folder) }
    let zip = try ZipArchiveWriter(url: folder.appendingPathComponent("out.zip"))
    #expect(throws: TranscriptError.self) {
      try zip.add(fileAt: folder.appendingPathComponent("nope.txt"), as: "nope.txt")
    }
    try zip.finish()
  }
}
