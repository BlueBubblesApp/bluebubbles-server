//  UploadStoreTests
//  Where uploaded bytes land, and the rules that keep a client-chosen name inside the directory.

import Foundation
import Testing

@testable import BBInterfaces

@Suite("Upload store")
struct UploadStoreTests {

  private func temporaryStore() -> UploadStore {
    UploadStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("bb-uploads-\(UUID().uuidString)")
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
    #expect(throws: InterfaceError.self) {
      try store.append(Data("cd".utf8), to: "t2", named: "clip.mov", expectingChunk: 1)
    }
  }

  @Test("A transfer id cannot escape the directory")
  func transferIDIsSanitised() {
    #expect(UploadStore.safeIdentifier("../../etc/passwd") == "------etc-passwd")
    #expect(UploadStore.safeIdentifier("ABC-123") == "ABC-123")
    #expect(!UploadStore.uniqueName(for: "/etc/passwd").contains("/"))
  }

  @Test("A group icon is found under any of the extensions Messages uses")
  func groupIconLookup() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-icons-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data().write(to: directory.appendingPathComponent("group-1.heic"))

    #expect(
      GroupIconStore.path(forGroupID: "group-1", in: directory)
        == directory.appendingPathComponent("group-1.heic").path
    )
    #expect(GroupIconStore.path(forGroupID: "group-2", in: directory) == nil)
    #expect(GroupIconStore.path(forGroupID: nil, in: directory) == nil)
    #expect(GroupIconStore.path(forGroupID: "", in: directory) == nil)
  }
}
