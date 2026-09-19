//  UploadStoreTests
//  Where uploaded bytes land, and the rules that keep a client-chosen name inside the directory.

import Foundation
import Testing

@testable import BBAppStore
@testable import BBInterfaces
@testable import BBMedia

@Suite("Upload store")
struct UploadStoreTests {

  private func temporaryStore(maximumTransferBytes: Int = UploadStore.defaultMaximumTransferBytes)
    -> UploadStore
  {
    UploadStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("bb-uploads-\(UUID().uuidString)"),
      maximumTransferBytes: maximumTransferBytes
    )
  }

  @Test("A whole file is written under a unique name inside the directory")
  func writesWholeFile() throws {
    let store = temporaryStore()
    let path = try store.write(Data("hello".utf8), named: "photo.jpg")
    #expect(path.hasPrefix(store.directory.path))
    #expect(path.hasSuffix("-photo.jpg"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("hello".utf8))
  }

  @Test("The directory is created owner-only")
  func directoryPermissions() throws {
    let store = temporaryStore()
    _ = try store.write(Data(), named: "x")
    let attributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o700)
  }

  @Test("Chunks append in order and chunk 0 truncates a retried transfer")
  func chunksAppendAndRetryTruncates() throws {
    let store = temporaryStore()
    let first = try store.append(Data("ab".utf8), to: "t1", named: "clip.mov", expectingChunk: 0)
    let second = try store.append(Data("cd".utf8), to: "t1", named: "clip.mov", expectingChunk: 1)
    #expect(first == second)
    #expect(try Data(contentsOf: URL(fileURLWithPath: first)) == Data("abcd".utf8))

    // A retry from chunk 0 starts over rather than appending to the failed attempt.
    _ = try store.append(Data("zz".utf8), to: "t1", named: "clip.mov", expectingChunk: 0)
    #expect(try Data(contentsOf: URL(fileURLWithPath: first)) == Data("zz".utf8))
  }

  @Test("A chunk before chunk 0 is refused as the client's mistake")
  func outOfOrderChunkIsRefused() {
    let store = temporaryStore()
    // `UploadError` rather than `InterfaceError` since `BBMedia` was split out: the domain
    // layer depends on that module, so it cannot name the domain layer's error type. The
    // SENTENCE and the 400 a client sees are unchanged — `UploadError+HTTP` holds them, and
    // `SplitModuleWireShapeTests` asserts it.
    #expect(throws: UploadError.self) {
      try store.append(Data("cd".utf8), to: "t2", named: "clip.mov", expectingChunk: 1)
    }
  }

  @Test("A transfer id cannot escape the directory")
  func transferIDIsSanitised() {
    #expect(UploadStore.safeIdentifier("../../etc/passwd") == "------etc-passwd")
    #expect(UploadStore.safeIdentifier("ABC-123") == "ABC-123")
    #expect(!UploadStore.uniqueName(for: "/etc/passwd").contains("/"))
  }

  // MARK: - Reclaiming

  /// Nothing reclaimed this directory before: every attachment any client had ever uploaded
  /// stayed for the life of the install, including the fragment a died-partway chunked
  /// transfer left behind. The limits are parameters so a test can cross them without
  /// waiting a day or writing two gigabytes.

  @Test("An upload past its age is reclaimed and a fresh one is kept")
  func sweepsByAge() throws {
    let store = temporaryStore()
    let old = try store.write(Data("old".utf8), named: "old.jpg")
    let fresh = try store.write(Data("fresh".utf8), named: "fresh.jpg")
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old)

    UploadStore.sweep(in: store.directory, maximumAge: 3600)

    #expect(!FileManager.default.fileExists(atPath: old))
    #expect(FileManager.default.fileExists(atPath: fresh))
  }

  /// A `stage` upload is a DIRECTORY, not a file: the name is preserved because it becomes
  /// the attachment's name, so uniqueness moved up a level. A sweep that understood only
  /// files would leave every staged upload behind, which is most of them.
  @Test("A staged upload directory is reclaimed too")
  func sweepsStagedDirectories() throws {
    let store = temporaryStore()
    let staged = try store.stage(Data("photo".utf8), named: "IMG_0001.jpg")
    let container = URL(fileURLWithPath: staged).deletingLastPathComponent()
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: container.path)

    UploadStore.sweep(in: store.directory, maximumAge: 3600)

    #expect(!FileManager.default.fileExists(atPath: container.path))
  }

  /// The budget is the backstop for a server uploaded to faster than the age limit reclaims.
  /// Oldest first, and it stops the moment the total is back inside.
  @Test("Over the budget, the oldest uploads go first")
  func sweepsToBudget() throws {
    let store = temporaryStore()
    var paths: [String] = []
    for index in 0..<5 {
      let path = try store.write(Data(repeating: 0x41, count: 1000), named: "f\(index).bin")
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(Double(index) - 100)],
        ofItemAtPath: path)
      paths.append(path)
    }

    // Room for two of the five.
    UploadStore.sweep(
      in: store.directory,
      maximumAge: 3600, sizeBudget: 2000)

    let survivors = paths.filter { FileManager.default.fileExists(atPath: $0) }
    #expect(survivors.count == 2, "\(survivors.count) of 5 survived a two-file budget")
    // The two NEWEST, which are the two most likely to still be waiting for their send.
    #expect(survivors.sorted() == Array(paths.suffix(2)).sorted())
  }

  // MARK: - The transfer ceiling

  /// `index < total` was the only bound the chunked route had, and `total` is the CLIENT's
  /// number: declare a billion chunks and append until the disk is full. The per-request
  /// ceiling bounds one request; nothing bounded the file every request appends to.

  @Test("A transfer is refused once it would grow past the ceiling")
  func appendRefusesPastTheCeiling() throws {
    let store = temporaryStore(maximumTransferBytes: 10)
    _ = try store.append(
      Data(repeating: 0x41, count: 6), to: "t1", named: "c.mov",
      expectingChunk: 0)
    // Six plus three is inside ten.
    _ = try store.append(
      Data(repeating: 0x42, count: 3), to: "t1", named: "c.mov",
      expectingChunk: 1)
    #expect(throws: UploadError.transferTooLarge(limit: 10)) {
      try store.append(
        Data(repeating: 0x43, count: 2), to: "t1", named: "c.mov",
        expectingChunk: 2)
    }
  }

  /// The half that makes the refusal worth anything. Leaving the partial file for the sweep
  /// means the attacker keeps every byte they wrote and only the last request failed.
  @Test("A refused transfer takes its partial file with it")
  func refusedTransferIsDeleted() throws {
    let store = temporaryStore(maximumTransferBytes: 10)
    let path = try store.append(
      Data(repeating: 0x41, count: 8), to: "t2", named: "c.mov",
      expectingChunk: 0)
    #expect(FileManager.default.fileExists(atPath: path))

    #expect(throws: UploadError.self) {
      try store.append(
        Data(repeating: 0x42, count: 8), to: "t2", named: "c.mov",
        expectingChunk: 1)
    }
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  /// Chunk 0 truncates, so it is the one chunk that can exceed the ceiling on its own.
  @Test("Chunk 0 is measured against the ceiling too")
  func firstChunkIsBounded() {
    let store = temporaryStore(maximumTransferBytes: 4)
    #expect(throws: UploadError.transferTooLarge(limit: 4)) {
      try store.append(
        Data(repeating: 0x41, count: 5), to: "t3", named: "c.mov",
        expectingChunk: 0)
    }
  }

  @Test("A sweep of a directory that does not exist is not an error")
  func sweepOfMissingDirectory() {
    UploadStore.sweep(
      in: FileManager.default.temporaryDirectory
        .appendingPathComponent("bb-absent-\(UUID().uuidString)"),
    )
  }
}
