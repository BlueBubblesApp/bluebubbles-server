//  DatabaseFileWatcher
//  kqueue vnode notifications on chat.db and its WAL sidecar, through `DispatchSource`.
//
//  Its own file so the primary signal is read apart from the detector that consumes it
//  (`ChangeDetector.swift`), which also runs the `PRAGMA data_version` backup and decides
//  what a wake means. This class only arms descriptors and calls back; it reads no rows.

import Dispatch
import Foundation
import Logging

import struct os.OSAllocatedUnfairLock

/// Watches chat.db and its WAL sidecar.
///
/// The WAL is the one that matters: SQLite in WAL mode appends there and only checkpoints
/// into the main file periodically, so a watcher looking only at `chat.db` sees activity in
/// bursts minutes late. Watching both is what makes delivery feel immediate.
///
/// `-shm` is deliberately not watched. SQLite writes it through `mmap`, and stores into a
/// mapping raise no vnode events, so a source on it never fires.
public final class DatabaseFileWatcher: @unchecked Sendable {

  private let paths: [String]
  private let queue = DispatchQueue(label: "bluebubbles.chatdb-watch")
  private let onChange: @Sendable () -> Void
  private let logger: Logger
  /// Path -> its armed source. Guarded because arming happens from the owner and, after a
  /// rename, from the watch queue.
  private let sources = OSAllocatedUnfairLock<[String: any DispatchSourceFileSystemObject]>(
    initialState: [:]
  )

  public init(
    databasePath: String,
    onChange: @escaping @Sendable () -> Void,
    logger: Logger = Logger(label: "bluebubbles.chatdb-watch")
  ) {
    self.paths = [databasePath, databasePath + "-wal"]
    self.onChange = onChange
    self.logger = logger
  }

  /// The paths with a live source, in declaration order.
  public var watchedPaths: [String] {
    sources.withLockUnchecked { state in paths.filter { state[$0] != nil } }
  }

  public func start() { armMissing() }

  /// Arms every path that exists and is not yet watched.
  ///
  /// A missing sidecar at startup is normal: the WAL exists only while a writer holds it,
  /// so `start()` skips it without error, and this is how it gets picked up later. The
  /// detector calls it on every backup pass; a file that appears is watched within one.
  public func armMissing() {
    for path in paths where !isWatching(path) { arm(path) }
  }

  private func isWatching(_ path: String) -> Bool {
    sources.withLockUnchecked { $0[path] != nil }
  }

  private func arm(_ path: String) {
    let descriptor = open(path, O_EVTONLY)
    guard descriptor >= 0 else { return }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      // .delete and .rename matter because a descriptor follows the vnode, not the
      // name: if the file is replaced, the source keeps watching the old, unlinked one
      // and silently goes deaf. Re-arm by name instead.
      eventMask: [.write, .extend, .delete, .rename, .link],
      queue: queue
    )

    source.setEventHandler { [weak self] in
      guard let self else { return }
      let flags = source.data
      if flags.contains(.delete) || flags.contains(.rename) {
        self.logger.debug(
          "chat.db file was replaced; re-arming the watcher",
          metadata: ["path": .string(path)])
        self.disarm(path)
        // Not inline: the replacement may not exist yet. If it still does not after the
        // delay, the next backup pass arms it.
        self.queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
          self?.arm(path)
        }
      }
      self.onChange()
    }
    source.setCancelHandler { close(descriptor) }

    let replaced = sources.withLockUnchecked { state -> (any DispatchSourceFileSystemObject)? in
      let previous = state[path]
      state[path] = source
      return previous
    }
    replaced?.cancel()
    source.resume()
  }

  private func disarm(_ path: String) {
    let source = sources.withLockUnchecked { $0.removeValue(forKey: path) }
    source?.cancel()
  }

  public func stop() {
    let all = sources.withLockUnchecked { state -> [any DispatchSourceFileSystemObject] in
      let values = Array(state.values)
      state.removeAll()
      return values
    }
    for source in all { source.cancel() }
  }

  deinit { stop() }
}
