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

  @Test("A staged file named `..` is written, under the fallback")
  func stagesAPathLikeName() throws {
    // This used to make the file's path the DIRECTORY above it, and the write failed.
    let store = temporaryStore()
    let path = try store.stage(Data("x".utf8), named: "..")
    #expect((path as NSString).lastPathComponent == AttachmentFilename.fallback)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("x".utf8))
  }

  @Test("Renaming to the name a file already has returns it as it is")
  func renameToTheSameName() throws {
    let store = temporaryStore()
    let staged = try store.stage(Data("x".utf8), named: "photo.jpg")
    #expect(try store.renamed(staged, to: "photo.jpg") == staged)
    // A name that cleans up to nothing keeps the current one rather than `attachment`.
    #expect(try store.renamed(staged, to: "..") == staged)
  }

  @Test("Renaming links the same bytes under the new name and keeps the original")
  func renameLinks() throws {
    let store = temporaryStore()
    let staged = try store.stage(Data("bytes".utf8), named: "IMG_0001.heic")
    let renamed = try store.renamed(staged, to: "../Beach.heic")

    #expect((renamed as NSString).lastPathComponent == "Beach.heic")
    #expect(renamed.hasPrefix(store.directory.path + "/"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: renamed)) == Data("bytes".utf8))
    // The original stays, for any other send that names it.
    #expect(FileManager.default.fileExists(atPath: staged))
    // One inode, two names: a link, not a second copy of the file.
    let inode = { (path: String) in
      try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? UInt64
    }
    #expect(try inode(renamed) == inode(staged))
  }

  @Test("The directory is created owner-only")
  func directoryPermissions() throws {
    let store = temporaryStore()
    _ = try store.write(Data(), named: "x")
    let attributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o700)
  }

  @Test("Chunks are joined by index whatever order they arrived in")
  func chunksJoinByIndex() throws {
    let store = temporaryStore()
    for (index, bytes) in [(2, "ef"), (0, "ab"), (1, "cd")] {
      try store.storeChunk(Data(bytes.utf8), transfer: "t1", index: index)
    }
    let path = try store.assembleChunks(transfer: "t1", expecting: 3, named: "clip.mov")
    #expect((path as NSString).lastPathComponent == "clip.mov")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("abcdef".utf8))
  }

  @Test("A retried chunk replaces the one it retries")
  func retriedChunkReplaces() throws {
    let store = temporaryStore()
    try store.storeChunk(Data("xx".utf8), transfer: "t1", index: 0)
    try store.storeChunk(Data("ab".utf8), transfer: "t1", index: 0)
    let path = try store.assembleChunks(transfer: "t1", expecting: 1, named: "clip.mov")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("ab".utf8))
  }

  @Test("Assembling with a chunk missing is refused with the counts")
  func missingChunkIsRefused() throws {
    let store = temporaryStore()
    try store.storeChunk(Data("cd".utf8), transfer: "t2", index: 1)
    #expect(throws: UploadError.missingChunks(expected: 2, found: 1)) {
      try store.assembleChunks(transfer: "t2", expecting: 2, named: "clip.mov")
    }
  }

  @Test("Assembly keeps the chunks; discarding drops them")
  func assemblyKeepsChunksUntilDiscarded() throws {
    let store = temporaryStore()
    try store.storeChunk(Data("ab".utf8), transfer: "t3", index: 0)
    _ = try store.assembleChunks(transfer: "t3", expecting: 1, named: "clip.mov")
    // A second assembly, which is what retrying a final request whose send failed does.
    _ = try store.assembleChunks(transfer: "t3", expecting: 1, named: "clip.mov")
    store.discardChunks(transfer: "t3")
    #expect(throws: UploadError.missingChunks(expected: 1, found: 0)) {
      try store.assembleChunks(transfer: "t3", expecting: 1, named: "clip.mov")
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
  /// number: declare a billion chunks and keep sending until the disk is full. The
  /// per-request ceiling bounds one request; nothing bounded the transfer.

  @Test("A transfer is refused once it would grow past the ceiling")
  func refusesPastTheCeiling() throws {
    let store = temporaryStore(maximumTransferBytes: 10)
    try store.storeChunk(Data(repeating: 0x41, count: 6), transfer: "t1", index: 0)
    // Six plus three is inside ten.
    try store.storeChunk(Data(repeating: 0x42, count: 3), transfer: "t1", index: 1)
    #expect(throws: UploadError.transferTooLarge(limit: 10)) {
      try store.storeChunk(Data(repeating: 0x43, count: 2), transfer: "t1", index: 2)
    }
  }

  @Test("A retried chunk is not counted twice against the ceiling")
  func retryIsNotGrowth() throws {
    let store = temporaryStore(maximumTransferBytes: 10)
    try store.storeChunk(Data(repeating: 0x41, count: 6), transfer: "t1", index: 0)
    try store.storeChunk(Data(repeating: 0x41, count: 6), transfer: "t1", index: 0)
    let path = try store.assembleChunks(transfer: "t1", expecting: 1, named: "c.mov")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count == 6)
  }

  /// The half that makes the refusal worth anything. Leaving the chunks for the sweep means
  /// the attacker keeps every byte they wrote and only the last request failed.
  @Test("A refused transfer takes its chunks with it")
  func refusedTransferIsDeleted() throws {
    let store = temporaryStore(maximumTransferBytes: 10)
    try store.storeChunk(Data(repeating: 0x41, count: 8), transfer: "t2", index: 0)
    #expect(throws: UploadError.self) {
      try store.storeChunk(Data(repeating: 0x42, count: 8), transfer: "t2", index: 1)
    }
    #expect(throws: UploadError.missingChunks(expected: 1, found: 0)) {
      try store.assembleChunks(transfer: "t2", expecting: 1, named: "c.mov")
    }
  }

  @Test("A single chunk is measured against the ceiling too")
  func firstChunkIsBounded() {
    let store = temporaryStore(maximumTransferBytes: 4)
    #expect(throws: UploadError.transferTooLarge(limit: 4)) {
      try store.storeChunk(Data(repeating: 0x41, count: 5), transfer: "t3", index: 0)
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
