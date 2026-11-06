//  DaemonLedger
//  Every tunnel process this server spawns, on disk, so none of them can outlive it unnoticed.
//
//  A daemon is a child of this process and nothing more. macOS has no way to ask that a child
//  die with its parent, and the daemon leads a process group of its OWN (see
//  `DaemonProcess.signalTree`), so nothing that ends this process reaches it. That leaves a
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
//
//  A ledger that cannot be read is not an empty one. Every write is a read-modify-write, so
//  treating an unreadable file as `[]` and saving over it discards the very pids the next
//  sweep exists to find. An entry that does not decode (a field added by another version, say)
//  is skipped and the rest kept, and a file that does not decode at all is set aside beside
//  the ledger as `.unreadable` rather than overwritten, with a warning either way.

import BBCore
import Darwin
import Foundation
import Logging

public final class DaemonLedger: Sendable {

  public struct Entry: Codable, Equatable, Sendable {
    public let name: String
    public let pid: Int32
    public let executablePath: String
    public let startedAt: Date
  }

  // There is no process-wide `shared` ledger, deliberately. One resolved from the support
  // directory as a static default is reached by anything that says nothing, a test
  // included, and the file it names is the one a real server reaps from. The composition
  // root builds one per server (`ServerComposition.SharedServices.daemonLedger`) and hands it
  // down; `DaemonLedgerPolicyTests` refuses a `shared` coming back.

  public let file: URL
  /// Serialises the read-modify-write of the file. Guards no memory: the file is the state.
  private let lock = Locked(())

  public init(file: URL) {
    self.file = file
  }

  // MARK: - Writing

  public func record(name: String, pid: pid_t, executablePath: String) {
    lock.withLock { _ in
      var entries = load().filter { $0.pid != pid }
      entries.append(
        Entry(name: name, pid: pid, executablePath: executablePath, startedAt: Date()))
      save(entries)
    }
  }

  public func forget(pid: pid_t) {
    lock.withLock { _ in
      let entries = load()
      let remaining = entries.filter { $0.pid != pid }
      if remaining.count != entries.count { save(remaining) }
    }
  }

  public func entries() -> [Entry] {
    lock.withLock { _ in load() }
  }

  // MARK: - Reading back

  /// Terminates every recorded daemon still running its recorded executable, waits for it
  /// to go, and empties the ledger. For the start of a process, before it spawns its own.
  ///
  /// Returns how many were killed, which is what the log line says.
  @discardableResult
  public func reapOrphans(logger: Logger) -> Int {
    let stale = lock.withLock { _ -> [Entry] in
      let entries = load()
      save([])
      return entries
    }
    var reaped = 0
    for entry in stale where Self.isRunning(entry) {
      logger.warning(
        "Terminating a daemon left behind by a previous server process",
        metadata: [
          "daemon": .string(entry.name),
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
          "daemon": .string(entry.name),
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

  private static let logger = Logger(label: "bluebubbles.proxy.daemon")

  /// One element of the file, decoded on its own so a bad one costs only itself.
  private struct LenientEntry: Decodable {
    let entry: Entry?
    init(from decoder: any Decoder) throws {
      // `try?`: a failure here is counted and logged by `load`, which sees the nil.
      entry = try? Entry(from: decoder)
    }
  }

  private func load() -> [Entry] {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    } catch {
      Self.logger.warning(
        "Could not read the daemon ledger",
        metadata: ["error": .string(String(describing: error))])
      return []
    }

    let decoded: [LenientEntry]
    do {
      decoded = try JSONDecoder().decode([LenientEntry].self, from: data)
    } catch {
      setAside(because: error)
      return []
    }
    let entries = decoded.compactMap(\.entry)
    if entries.count != decoded.count {
      Self.logger.warning(
        "Skipped daemon ledger entries that could not be read",
        metadata: ["skipped": .stringConvertible(decoded.count - entries.count)])
    }
    return entries
  }

  /// Moves an undecodable ledger out of the way, so the save that follows does not destroy
  /// the only record of what it named.
  private func setAside(because error: any Error) {
    let aside = file.appendingPathExtension("unreadable")
    // `try?`: there is normally no earlier copy to remove; a failed move is logged below.
    try? FileManager.default.removeItem(at: aside)
    do {
      try FileManager.default.moveItem(at: file, to: aside)
      Self.logger.warning(
        "The daemon ledger could not be decoded; set it aside and started a new one",
        metadata: [
          "error": .string(String(describing: error)), "keptAt": .string(aside.lastPathComponent),
        ])
    } catch let moveError {
      Self.logger.warning(
        "The daemon ledger could not be decoded or set aside; it will be replaced",
        metadata: [
          "error": .string(String(describing: error)),
          "moveError": .string(String(describing: moveError)),
        ])
    }
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
      Self.logger.warning(
        "Could not write the daemon ledger",
        metadata: ["error": .string(String(describing: error))])
    }
  }
}
