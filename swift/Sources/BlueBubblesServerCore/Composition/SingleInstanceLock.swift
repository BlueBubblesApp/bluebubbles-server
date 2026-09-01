//  SingleInstanceLock
//  One server per user account, enforced before anything is built.
//
//  Two instances do not fail cleanly — they CORRUPT each other, and the failure looks like a
//  bug somewhere else entirely. Observed while testing FaceTime: three copies were running,
//  and the two that lost the race for port 1234 stayed alive retrying, tearing down and
//  rebinding the Private API socket every few seconds. Each rebind disconnected the injected
//  helpers from the instance that HAD won the port, so the working server intermittently lost
//  the helper for no visible reason. The port conflict was reported; the socket damage was
//  not.
//
//  WHY flock AND NOT A PID FILE. A pid file records an intention; the lock records a fact.
//  The kernel releases an `flock` when the holder dies — including on SIGKILL, a panic, or a
//  yanked power cord — so there is no stale lock to clean up and no window where a crashed
//  server keeps its successor out. A pid file has to be validated against a live process,
//  which races: the pid may have been recycled by something unrelated. The pid is still
//  WRITTEN here, but only so the error message can name the process; it is never the lock.
//
//  Scope is the user account, not the machine. Two macOS users each running their own server
//  have separate home directories and therefore separate locks, which is the supported setup
//  the port-conflict message already refers to.

import BBHandlers
import BBInterfaces
import BBPrivateAPIContract
import Darwin
import Foundation

public enum SingleInstanceLock {

  /// The open descriptor, held for the life of the process.
  ///
  /// Never closed on purpose: closing releases the lock, so this deliberately leaks. The
  /// kernel reclaims it at exit, which is exactly the release semantics wanted.
  private nonisolated(unsafe) static var descriptor: Int32 = -1

  public static var defaultPath: String {
    SocketLocation.supportDirectory + "/bluebubbles-server.lock"
  }

  /// Another instance already holds the lock.
  public struct AlreadyRunning: LocalizedError {
    public let existingPID: pid_t?
    public let path: String

    public var errorDescription: String? {
      let who = existingPID.map { "process \($0)" } ?? "another process"
      return """
        BlueBubbles Server is already running (\(who)).

        Running two copies does not just fail on the port — they fight over the \
        Private API socket, which disconnects the helpers from whichever copy is \
        actually serving requests. Stop the running server before starting another.

        Lock: \(path)
        """
    }
  }

  /// Takes the lock, or throws `AlreadyRunning`.
  ///
  /// Call before building the server: the point is to fail before touching the port, the
  /// socket, or the database, none of which tolerate a second writer.
  @discardableResult
  public static func acquire(path: String = SingleInstanceLock.defaultPath) throws -> Int32 {
    // Idempotent. The GUI app can stop and restart the server inside ONE process, and an
    // flock is tied to the open file description rather than the process — so a second
    // open+flock from the same process is refused just like a stranger's would be, and
    // restarting would fail with an error naming our own pid.
    if descriptor >= 0 { return descriptor }

    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )

    let fd = open(path, O_RDWR | O_CREAT, 0o644)
    guard fd >= 0 else {
      throw NSError(
        domain: NSPOSIXErrorDomain, code: Int(errno),
        userInfo: [
          NSLocalizedDescriptionKey:
            "Could not open the single-instance lock at \(path): "
            + String(cString: strerror(errno))
        ]
      )
    }

    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let failure = errno
      // Read the holder's pid for the message. Best effort — the lock is the authority,
      // and a missing or unreadable pid must not turn a clean refusal into a crash.
      let existing = (try? String(contentsOfFile: path, encoding: .utf8))
        .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      close(fd)
      guard failure == EWOULDBLOCK else {
        throw NSError(
          domain: NSPOSIXErrorDomain, code: Int(failure),
          userInfo: [
            NSLocalizedDescriptionKey:
              "Could not take the single-instance lock at \(path): "
              + String(cString: strerror(failure))
          ]
        )
      }
      throw AlreadyRunning(existingPID: existing, path: path)
    }

    // Ours. Record the pid so a future refusal can name us.
    ftruncate(fd, 0)
    let pid = "\(getpid())"
    _ = pid.withCString { write(fd, $0, strlen($0)) }

    descriptor = fd
    return fd
  }

  /// Releases the lock. Exposed for tests, which need to take and drop it repeatedly in one
  /// process; the server itself never calls this and relies on process exit.
  public static func release() {
    guard descriptor >= 0 else { return }
    flock(descriptor, LOCK_UN)
    close(descriptor)
    descriptor = -1
  }
}
