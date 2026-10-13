//  DatabaseFileWatcherTests
//  The primary signal, against real files.
//
//  What matters is not that kqueue works; it is that the watcher is armed on the files
//  that will actually be written, keeps being armed after they are replaced, and picks up
//  a sidecar that did not exist when it started. Each of those is a way to go quietly deaf.

import BBTestSupport
import Foundation
import Testing

@testable import BBIMessage

@Suite("chat.db file watcher", .serialized)
struct DatabaseFileWatcherTests {

  /// A fresh "chat.db" path in a private directory. Only the main file exists to begin
  /// with; tests create the sidecar when they mean to.
  private struct Files {
    let directory: URL
    let database: String
    var wal: String { database + "-wal" }

    init() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("bb-watch-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      database = directory.appendingPathComponent("chat.db").path
      FileManager.default.createFile(atPath: database, contents: Data("head".utf8))
    }

    func append(_ path: String) throws {
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("more".utf8))
    }

    func tearDown() { try? FileManager.default.removeItem(at: directory) }
  }

  /// Counts wakes and lets a test wait for the next one.
  private final class Wakes: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func fire() {
      lock.lock()
      count += 1
      lock.unlock()
    }

    var total: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }

    /// Polls rather than blocks: the callback arrives on a dispatch queue and the test
    /// on a cooperative thread, and a semaphore across that boundary is the deadlock the
    /// codebase forbids.
    func waitForWakes(atLeast expected: Int, timeout: Duration = .seconds(3)) async throws {
      try await waitUntil("\(expected) wake(s)", timeout: timeout) { total >= expected }
    }
  }

  @Test("A write to the database file wakes the detector")
  func writeToDatabaseFires() async throws {
    let files = try Files()
    defer { files.tearDown() }
    let wakes = Wakes()
    let watcher = DatabaseFileWatcher(databasePath: files.database, onChange: { wakes.fire() })
    defer { watcher.stop() }
    watcher.start()

    #expect(watcher.watchedPaths == [files.database])
    try files.append(files.database)
    try await wakes.waitForWakes(atLeast: 1)
  }

  @Test("A sidecar that appears after startup is armed by the next backup pass")
  func lateSidecarIsArmed() async throws {
    // The WAL exists only while Messages holds the database. Start without one, as on a
    // Mac where the server came up before Messages did.
    let files = try Files()
    defer { files.tearDown() }
    let wakes = Wakes()
    let watcher = DatabaseFileWatcher(databasePath: files.database, onChange: { wakes.fire() })
    defer { watcher.stop() }
    watcher.start()
    #expect(watcher.watchedPaths == [files.database])

    FileManager.default.createFile(atPath: files.wal, contents: Data("wal".utf8))
    watcher.armMissing()
    #expect(watcher.watchedPaths == [files.database, files.wal])

    try files.append(files.wal)
    try await wakes.waitForWakes(atLeast: 1)
  }

  @Test("A replaced file is watched again under its name")
  func replacedFileIsRearmed() async throws {
    // A descriptor follows the vnode. Delete the file and create a new one at the same
    // path, and a watcher that did not re-arm by name would be watching the unlinked
    // original forever.
    let files = try Files()
    defer { files.tearDown() }
    let wakes = Wakes()
    let watcher = DatabaseFileWatcher(databasePath: files.database, onChange: { wakes.fire() })
    defer { watcher.stop() }
    watcher.start()

    try FileManager.default.removeItem(atPath: files.database)
    // The delete itself is an event.
    try await wakes.waitForWakes(atLeast: 1)
    FileManager.default.createFile(atPath: files.database, contents: Data("new".utf8))

    // Re-arming waits 250ms for the replacement to exist.
    try await waitUntil("the watcher to re-arm on the replacement file", timeout: .seconds(3)) {
      watcher.watchedPaths == [files.database]
    }

    let before = wakes.total
    try files.append(files.database)
    try await wakes.waitForWakes(atLeast: before + 1)
  }

  @Test("Stopping cancels every source")
  func stopClearsSources() throws {
    let files = try Files()
    defer { files.tearDown() }
    let watcher = DatabaseFileWatcher(databasePath: files.database, onChange: {})
    watcher.start()
    #expect(!watcher.watchedPaths.isEmpty)
    watcher.stop()
    #expect(watcher.watchedPaths.isEmpty)
  }
}
