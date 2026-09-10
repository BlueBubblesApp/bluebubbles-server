//  DaemonLedger
//  Every tunnel process this server spawns, on disk, so none of them can outlive it unnoticed.
//
//  A daemon is a child of this process and nothing more. macOS has no way to ask that a child
//  die with its parent, and `Process` puts the child in OUR process group, so the one signal
//  that would take the whole tree down would take the server down with it. That leaves a
//  daemon alive whenever this process ends without stopping it: a crash, a `kill -9`, a quit
//  that hit its shutdown deadline while a connection method was mid-restart. Measured on a
//  development Mac after a day of relaunches: sixteen `cloudflared` processes, every one
//  parented to launchd, every one holding a quick tunnel to a server that no longer existed.
//
//  So each spawn is written here with its pid and executable, and forgotten when it stops.
//  Two readers: the next start, which terminates anything still alive from a previous
//  process, and the quit path, which sends a SIGTERM to whatever an abandoned shutdown left
//  behind: one syscall each, which is the whole budget a deadline-bound quit has.
//
//  Before killing, the pid is checked against the recorded executable. A pid is not an
//  identity (the number is reused) and an entry left by a crash may by now name some
//  unrelated program. Only a process still running the very binary that was spawned is
//  signalled; everything else is simply forgotten.

import BBCore
import Darwin
import Foundation
import Logging

public final class DaemonLedger: @unchecked Sendable {

  public struct Entry: Codable, Equatable, Sendable {
    public let name: String
    public let pid: Int32
    public let executablePath: String
    public let startedAt: Date
  }

  /// The ledger every daemon in this process records to.
  public static let shared = DaemonLedger(
    file: ApplicationSupport.directory.appendingPathComponent("daemons.json")
  )

  public let file: URL
  private let lock = NSLock()

  public init(file: URL) {
    self.file = file
  }

  // MARK: - Writing

  public func record(name: String, pid: pid_t, executablePath: String) {
    lock.withLock {
      var entries = load().filter { $0.pid != pid }
      entries.append(
        Entry(name: name, pid: pid, executablePath: executablePath, startedAt: Date()))
      save(entries)
    }
  }

  public func forget(pid: pid_t) {
    lock.withLock {
      let entries = load()
      let remaining = entries.filter { $0.pid != pid }
      if remaining.count != entries.count { save(remaining) }
    }
  }

  public func entries() -> [Entry] {
    lock.withLock { load() }
  }

  // MARK: - Reading back

  /// Terminates every recorded daemon still running its recorded executable, waits for it
  /// to go, and empties the ledger. For the start of a process, before it spawns its own.
  ///
  /// Returns how many were killed, which is what the log line says.
  @discardableResult
  public func reapOrphans(logger: Logger) -> Int {
    let stale = lock.withLock { () -> [Entry] in
      let entries = load()
      save([])
      return entries
    }
    var reaped = 0
    for entry in stale where Self.isRunning(entry) {
      logger.warning(
        "Terminating a daemon left behind by a previous server process",
        metadata: [
          "name": .string(entry.name),
          "pid": .stringConvertible(entry.pid),
          "startedAt": .stringConvertible(entry.startedAt),
        ])
      kill(entry.pid, SIGTERM)
      // Briefly, so the port and the tunnel it held are free before the replacement
      // asks for them. SIGKILL after that: a daemon that ignores SIGTERM for this long
      // is not going to honour it later either.
      for _ in 0..<20 where Self.isAlive(entry.pid) {
        usleep(100_000)
      }
      if Self.isAlive(entry.pid) { kill(entry.pid, SIGKILL) }
      reaped += 1
    }
    return reaped
  }

  /// Sends SIGTERM to every recorded daemon still running its recorded executable, and
  /// returns at once. For a process on its way out that could not stop them properly.
  ///
  /// Entries are KEPT: a daemon that has not yet exited when this process does is still an
  /// orphan for the next start to check on.
  public func terminateAll(logger: Logger) {
    for entry in entries() where Self.isRunning(entry) {
      logger.warning(
        "Signalling a daemon that was not stopped before exit",
        metadata: [
          "name": .string(entry.name),
          "pid": .stringConvertible(entry.pid),
        ])
      kill(entry.pid, SIGTERM)
    }
  }

  // MARK: - Identity

  /// Whether the pid is alive AND is the program the entry says it is.
  static func isRunning(_ entry: Entry) -> Bool {
    guard isAlive(entry.pid), let path = executablePath(of: entry.pid) else { return false }
    return canonical(path) == canonical(entry.executablePath)
  }

  static func isAlive(_ pid: pid_t) -> Bool {
    // Signal 0 delivers nothing and reports whether the process exists. `EPERM` means it
    // exists and is not ours, which for this purpose is "not ours to touch".
    kill(pid, 0) == 0
  }

  static func executablePath(of pid: pid_t) -> String? {
    // `PROC_PIDPATHINFO_MAXSIZE`, which the Darwin overlay does not export: four path lengths.
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    // `proc_pidpath` returns the length WITHOUT the null terminator, so the prefix is the
    // path exactly. `String(cString:)` is deprecated and would scan for the terminator we
    // already know the position of.
    return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// Symlinks resolved on both sides, so `current` links and `/var` versus `/private/var`
  /// do not make the same file look like two.
  private static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  // MARK: - Storage

  private func load() -> [Entry] {
    guard let data = try? Data(contentsOf: file) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }

  private func save(_ entries: [Entry]) {
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(entries).write(to: file, options: .atomic)
    } catch {
      // A ledger that cannot be written costs the next start its sweep, nothing more.
      Logger(label: "bluebubbles.proxy.daemon").warning(
        "Could not write the daemon ledger",
        metadata: ["error": .string(String(describing: error))])
    }
  }
}
