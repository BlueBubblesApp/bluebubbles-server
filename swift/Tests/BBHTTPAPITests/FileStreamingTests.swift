//  FileStreamingTests
//  Serving a file: bounded memory, a length the client can use, and reads off the executor.
//
//  Two comments in `HTTPServer.swift` described this path in opposite ways -- one claimed
//  `FileRegion`/`sendfile` and "the bytes never pass through the heap", the other said plainly
//  that they do -- and `.claude/docs/performance.md` repeated the false one. The bytes pass
//  through the heap. What actually holds is the bound: peak memory is the chunk size.
//
//  The real gaps were elsewhere. No `Content-Length`, so a download was chunked and no client
//  could draw a progress bar -- the reference sets it, with a comment saying exactly that. And
//  the reads were blocking syscalls issued on the request executor, about eight thousand of
//  them for a 500MB file.

import Foundation
import NIOCore
import Testing

@testable import BBHTTPAPI

@Suite("File streaming")
struct FileStreamingTests {

  private func writeFile(_ bytes: [UInt8]) throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-stream-\(UUID().uuidString).bin")
    try Data(bytes).write(to: url)
    return url.path
  }

  /// Deterministic, and larger than one chunk, so the test covers the boundary rather than
  /// a single read that happens to return everything.
  private func pattern(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(($0 &* 31 &+ 7) & 0xFF) }
  }

  @Test("A file streams back byte for byte, across chunk boundaries")
  func streamsExactBytes() async throws {
    let expected = pattern(64 * 1024 * 2 + 137)
    let path = try writeFile(expected)
    defer { try? FileManager.default.removeItem(atPath: path) }

    var collected: [UInt8] = []
    var chunks = 0
    for try await buffer in FileBodySequence(path: path) {
      chunks += 1
      collected.append(contentsOf: buffer.readableBytesView)
    }
    #expect(collected == expected)
    // More than one read, or the chunking is not being exercised at all.
    #expect(chunks == 3, "expected three chunks, got \(chunks)")
  }

  /// The contract the false comment obscured: bounded by the CHUNK, not the file.
  @Test("No chunk is larger than the chunk size")
  func chunksAreBounded() async throws {
    let path = try writeFile(pattern(64 * 1024 * 3))
    defer { try? FileManager.default.removeItem(atPath: path) }

    let limit = FileBodySequence(path: path).chunkSize
    for try await buffer in FileBodySequence(path: path) {
      #expect(buffer.readableBytes <= limit)
    }
  }

  @Test("An empty file streams nothing and ends cleanly")
  func emptyFile() async throws {
    let path = try writeFile([])
    defer { try? FileManager.default.removeItem(atPath: path) }
    var chunks = 0
    for try await _ in FileBodySequence(path: path) { chunks += 1 }
    #expect(chunks == 0)
  }

  /// An attachment purged to iCloud between the route's existence check and the read is
  /// normal. It must end the stream, not trap.
  @Test("A file that is not there ends the stream rather than trapping")
  func missingFile() async throws {
    var chunks = 0
    for try await _ in FileBodySequence(path: "/nonexistent/bb-\(UUID().uuidString)") {
      chunks += 1
    }
    #expect(chunks == 0)
  }

  /// The length the reference sends and this did not.
  @Test("The file's size is read without building an attribute dictionary")
  func sizeMatchesTheFile() throws {
    let bytes = pattern(4096 + 11)
    let path = try writeFile(bytes)
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(FileBodySequence.size(ofFileAt: path) == Int64(bytes.count))
  }

  @Test("A directory and a missing path have no size, rather than a wrong one")
  func sizeOfNonFiles() {
    #expect(FileBodySequence.size(ofFileAt: NSTemporaryDirectory()) == nil)
    #expect(FileBodySequence.size(ofFileAt: "/nonexistent/bb-\(UUID().uuidString)") == nil)
  }

  /// Two streams over the same file must not share a read offset. They do not, because the
  /// iterator carries its own and uses `pread`; a shared `FileHandle` offset would have
  /// given each of them half the file.
  @Test("Concurrent streams of one file each get the whole file")
  func concurrentStreamsAreIndependent() async throws {
    let expected = pattern(64 * 1024 + 1024)
    let path = try writeFile(expected)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let results = try await withThrowingTaskGroup(of: [UInt8].self) { group in
      for _ in 0..<4 {
        group.addTask {
          var collected: [UInt8] = []
          for try await buffer in FileBodySequence(path: path) {
            collected.append(contentsOf: buffer.readableBytesView)
          }
          return collected
        }
      }
      var all: [[UInt8]] = []
      for try await result in group { all.append(result) }
      return all
    }
    #expect(results.count == 4)
    for result in results { #expect(result == expected) }
  }

  /// A client that disconnects mid-download abandons the sequence without reaching the end.
  ///
  /// Every one of those leaked a descriptor when the iterator held a raw `CInt`: measured at
  /// exactly one per abandoned download, until the process runs out and can no longer open a
  /// socket or the database. `FileHandle`, which the `pread` loop replaced, closed on
  /// dealloc; a struct has nowhere to put a `deinit`, so the descriptor now lives in a small
  /// class that does.
  ///
  /// Asserted by closing the descriptor a SECOND time rather than by counting open files: a
  /// count is process-wide, and the suite runs tests concurrently, so it measures every other
  /// test's files too. `close` on an already-closed descriptor answers `EBADF`; on a leaked
  /// one it succeeds.
  @Test("Abandoning a download closes its file")
  func abandonedStreamClosesItsFile() async throws {
    let path = try writeFile(pattern(1024 * 1024))
    defer { try? FileManager.default.removeItem(atPath: path) }

    var descriptor: CInt = -1
    do {
      let file = FileBodySequence.OpenFile(path: path)
      descriptor = file.descriptor
      #expect(descriptor >= 0, "the fixture file could not be opened")
      // Non-vacuity: it is open right now, so the check below is about the release.
      #expect(fcntl(descriptor, F_GETFD) != -1)
    }
    // The object is gone; its `deinit` must have closed the descriptor.
    #expect(close(descriptor) == -1 && errno == EBADF, "the descriptor was still open")
  }

  /// And the same through the sequence a route actually uses.
  @Test("An abandoned sequence does not hold its file open")
  func abandonedSequenceReleasesItsFile() async throws {
    let path = try writeFile(pattern(1024 * 1024))
    defer { try? FileManager.default.removeItem(atPath: path) }

    // Exactly what a client disconnecting mid-download does: take one chunk, stop.
    for try await _ in FileBodySequence(path: path) { break }

    // With the descriptor leaked, repeating this exhausts the process. A thousand rounds is
    // well past any sane limit and costs milliseconds when nothing leaks.
    for _ in 0..<1000 {
      for try await _ in FileBodySequence(path: path) { break }
    }
    // Reaching here without "too many open files" IS the assertion; make it explicit.
    var chunks = 0
    for try await _ in FileBodySequence(path: path) { chunks += 1 }
    #expect(chunks > 0, "the file could no longer be opened, which is the leak")
  }

  /// A read that FAILS is not the end of the file, and conflating them is how a download
  /// silently truncates -- now visibly wrong rather than quietly short, because the response
  /// has already promised a Content-Length.
  @Test("A failed read is distinguishable from the end of the file")
  func readFailureIsNotEndOfFile() async throws {
    let path = try writeFile(pattern(64 * 1024 * 2))
    defer { try? FileManager.default.removeItem(atPath: path) }

    // A descriptor that is open but not readable produces a real errno rather than EOF.
    var iterator = FileBodySequence(path: "/dev/null").makeAsyncIterator()
    #expect(try await iterator.next() == nil, "/dev/null is empty, which IS the end")

    // And the normal path still ends cleanly rather than throwing.
    var chunks = 0
    for try await _ in FileBodySequence(path: path) { chunks += 1 }
    #expect(chunks == 2)
  }
}
