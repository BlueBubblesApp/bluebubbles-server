//  SingleInstanceLockTests
//  One server per account.
//
//  These use a temporary lock path rather than the real one, so running the suite never
//  contends with a server the developer has running.

import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Single instance lock", .serialized)
struct SingleInstanceLockTests {

  private func temporaryPath() -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-lock-\(UUID().uuidString).lock").path
  }

  @Test("Acquiring writes our pid so a refusal can name the holder")
  func acquireRecordsPID() throws {
    let path = temporaryPath()
    defer {
      SingleInstanceLock.release()
      try? FileManager.default.removeItem(atPath: path)
    }

    try SingleInstanceLock.acquire(path: path)
    let recorded = try String(contentsOfFile: path, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(recorded == "\(getpid())")
  }

  /// The GUI app stops and restarts the server inside one process. An flock belongs to the
  /// open file description, not the process, so a naive second acquire would refuse itself.
  @Test("Acquiring twice in one process is allowed")
  func acquireIsIdempotent() throws {
    let path = temporaryPath()
    defer {
      SingleInstanceLock.release()
      try? FileManager.default.removeItem(atPath: path)
    }

    let first = try SingleInstanceLock.acquire(path: path)
    let second = try SingleInstanceLock.acquire(path: path)
    #expect(first == second)
  }

  /// The lock has to be held across a real process boundary — that is the entire point, and
  /// it cannot be proven from inside one process, where the idempotence rule applies.
  @Test("A second process is refused while the first holds the lock")
  func secondProcessIsRefused() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }

    // A child that takes the lock and holds it until killed.
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    holder.arguments = [
      "python3", "-c",
      """
      import fcntl, os, sys, time
      fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
      os.ftruncate(fd, 0)
      os.write(fd, str(os.getpid()).encode())
      print("locked", flush=True)
      time.sleep(30)
      """, path,
    ]
    let pipe = Pipe()
    holder.standardOutput = pipe
    try holder.run()
    defer { holder.terminate() }

    // Wait for the child to confirm it holds the lock.
    var ready = false
    for _ in 0..<100 where !ready {
      if let line = try? pipe.fileHandleForReading.read(upToCount: 7),
        String(data: line, encoding: .utf8)?.contains("locked") == true
      {
        ready = true
      }
    }
    #expect(ready, "the holder process never took the lock")

    #expect(throws: SingleInstanceLock.AlreadyRunning.self) {
      try SingleInstanceLock.acquire(path: path)
    }
  }

  /// The reason for flock over a pid file: a killed holder must not lock out its successor.
  /// SIGKILL leaves no chance to clean up, so a pid file would still be sitting there.
  @Test("A killed holder releases the lock, leaving no stale state")
  func killedHolderReleasesLock() throws {
    let path = temporaryPath()
    defer {
      SingleInstanceLock.release()
      try? FileManager.default.removeItem(atPath: path)
    }

    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    holder.arguments = [
      "python3", "-c",
      """
      import fcntl, os, sys, time
      fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
      os.ftruncate(fd, 0)
      os.write(fd, str(os.getpid()).encode())
      print("locked", flush=True)
      time.sleep(30)
      """, path,
    ]
    let pipe = Pipe()
    holder.standardOutput = pipe
    try holder.run()
    _ = try? pipe.fileHandleForReading.read(upToCount: 7)

    // SIGKILL: no cleanup runs, so only the kernel can have released this.
    kill(holder.processIdentifier, SIGKILL)
    holder.waitUntilExit()

    #expect(throws: Never.self) { try SingleInstanceLock.acquire(path: path) }
  }
}
