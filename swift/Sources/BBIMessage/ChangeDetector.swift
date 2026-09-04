//  ChangeDetector
//  Watches chat.db and turns file activity into message change events.
//
//  Two signals, in a fixed order of trust:
//
//    1. PRIMARY — kqueue vnode notifications on chat.db and its -wal sidecar, through
//       `DispatchSource`, on descriptors this process holds open. The kernel delivers them
//       directly; nothing is coalesced by a daemon or delayed by a poll. A write to the WAL
//       wakes the detector within the debounce, and that is where every message normally
//       arrives from.
//    2. BACKUP — every 30 seconds, `PRAGMA data_version`. SQLite bumps it on the reading
//       connection whenever any other connection commits, and answering costs a read of the
//       WAL index in shared memory: microseconds, no disk, no file-system event required.
//       Unchanged means nothing was committed and NO query runs. Changed means the watcher
//       missed something — a descriptor gone stale, a sidecar that did not exist at startup,
//       events that stopped being delivered — and the query runs then.
//
//  The old server relied on FSEvents alone, and on some Macs those stop arriving once the
//  disk has been idle for a while; users wrote "pokers" that touched chat.db to wake it up.
//  The backup makes that unnecessary without polling the table: a Mac with nothing
//  happening runs one shared-memory read every 30 seconds, not a query every second.
//
//  What is preserved exactly, because getting it wrong loses messages:
//    - The DUAL LOOKBACK. A 30-minute fast window on every tick (Apple only permits edits
//      within ~15 minutes and unsends within ~2), widening to a full 7 days every 5 minutes
//      to catch read receipts and notification flags on older messages. The wide pass is
//      skipped when nothing has been committed since the last one — a receipt is a commit.
//    - Querying by `date` and filtering the other timestamps in memory. `date` is the only
//      one of them with an index in Apple's schema — and we cannot add one — so an OR across
//      all of them full-scans `message`, which is the worst case on the old hardware this
//      targets.
//    - The >24h clamp, so a machine that slept for a week does not replay a week of history
//      as new messages on wake.
//
//  See `.claude/docs/database.md`.

import BBCore
import BBDiagnostics
import Dispatch
import Foundation
import Logging
import struct os.OSAllocatedUnfairLock

// MARK: - File watching

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
  /// A missing sidecar at startup is normal — the WAL exists only while a writer holds it —
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

// MARK: - Change detection

public struct ChangeDetectorConfiguration: Sendable {
  /// Floor between two ticks, and the debounce on file events. 500ms minimum: below that, a
  /// busy conversation produces more queries than messages.
  public var pollInterval: Duration
  /// How often the backup pass asks SQLite whether anything was committed. It is a
  /// shared-memory read, not a query, so the cost of the interval is latency in the one
  /// case the file watcher missed something — not CPU.
  public var backupInterval: Duration
  /// The fast window, on every tick.
  public var fastLookback: Duration
  /// The wide window, periodically.
  public var reconcileLookback: Duration
  public var reconcileInterval: Duration
  /// Overlap added to the cursor so a message landing between two ticks is not skipped.
  public var overlap: Duration
  /// A cursor older than this is clamped. Without it, waking a sleeping Mac replays
  /// everything since it slept as brand-new messages.
  public var maximumCatchUp: Duration

  public init(
    pollInterval: Duration = .milliseconds(1000),
    backupInterval: Duration = .seconds(30),
    fastLookback: Duration = .seconds(1800),
    reconcileLookback: Duration = .seconds(604_800),
    reconcileInterval: Duration = .seconds(300),
    overlap: Duration = .seconds(30),
    maximumCatchUp: Duration = .seconds(86_400)
  ) {
    self.pollInterval = max(pollInterval, .milliseconds(500))
    self.backupInterval = backupInterval
    self.fastLookback = fastLookback
    self.reconcileLookback = reconcileLookback
    self.reconcileInterval = reconcileInterval
    self.overlap = overlap
    self.maximumCatchUp = maximumCatchUp
  }
}

/// What changed about a message. Lets a consumer emit `new-message` versus `updated-message`
/// without re-deriving it, and lets a subscriber filter on the specific field.
public struct MessageChange: Sendable {
  public let message: IMessageRow
  public let isNew: Bool
  public let changedFields: Set<MessageField>

  public init(message: IMessageRow, isNew: Bool, changedFields: Set<MessageField>) {
    self.message = message
    self.isNew = isNew
    self.changedFields = changedFields
  }
}

public enum MessageField: String, Sendable, CaseIterable, Hashable {
  case delivered
  case read
  case played
  case edited
  case retracted
  case notifiedRecipient
  case error
}

public actor ChangeDetector {

  private let repository: MessageRepository
  private let configuration: ChangeDetectorConfiguration
  private let logger: Logger

  /// GUID -> the timestamps we last saw, so a change is detected by comparison rather than
  /// by trusting the query. Bounded: an unbounded map here is one of the leaks the current
  /// server has been patching.
  private var seen: BoundedCache<String, MessageFingerprint>

  private var cursor: Date
  private var lastReconcile: Date = .distantPast
  /// `data_version` as read at the start of the last tick. Nil until the first tick, and
  /// nil again if the read failed — either way the backup pass ticks rather than guesses.
  private var lastChangeToken: Int?
  /// `data_version` at the last wide pass. Equal to the current one means no commit since,
  /// so there is nothing for a wide pass to find.
  private var reconcileToken: Int?
  private var watcher: DatabaseFileWatcher?
  private var pollTask: Task<Void, Never>?
  /// Set by the file watcher, cleared by the loop. Distinguishes a wake the watcher raised
  /// (query unconditionally) from a backup wake (ask SQLite first), and survives the two
  /// being coalesced into one.
  private nonisolated let fileEventPending = OSAllocatedUnfairLock(initialState: false)

  /// How many times the table was queried. For tests: the point of the backup pass is that
  /// this does NOT grow while nothing is committed.
  private(set) var tickCount = 0
  private(set) var reconcileCount = 0

  struct MessageFingerprint: Sendable {
    let date: Int64?
    let dateRead: Int64?
    let dateDelivered: Int64?
    let datePlayed: Int64?
    let dateEdited: Int64?
    let dateRetracted: Int64?
    let didNotifyRecipient: Bool?
    let error: Int
  }

  public init(
    repository: MessageRepository,
    configuration: ChangeDetectorConfiguration = ChangeDetectorConfiguration(),
    startingFrom: Date = Date(),
    cacheCapacity: Int = 5_000,
    logger: Logger = Logger(label: "bluebubbles.change-detector")
  ) {
    self.repository = repository
    self.configuration = configuration
    self.cursor = startingFrom
    self.seen = BoundedCache(capacity: cacheCapacity, ttl: .seconds(604_800))
    self.logger = logger
  }

  /// Emits changes as they are detected.
  ///
  /// Bounded so that a consumer which stalls drops changes rather than backing up into the
  /// detector. Detection must never be the thing that waits.
  ///
  /// `databasePath` arms the file watcher, which is the primary signal: a write to chat.db
  /// or its WAL queries within the debounce. With or without it, the backup pass runs every
  /// `backupInterval` and queries only when SQLite reports a commit the watcher did not
  /// wake us for. One tick runs immediately, to seed the fingerprint cache so the first
  /// real event does not pay for it.
  public func changes(watching databasePath: String? = nil) -> AsyncStream<[MessageChange]> {
    let (stream, continuation) = AsyncStream<[MessageChange]>.makeStream(
      bufferingPolicy: .bufferingNewest(32)
    )

    // Coalesces a burst of file events into one wake. `bufferingNewest(1)` IS the
    // debounce: a hundred WAL writes while a tick is in flight collapse into one
    // pending wake rather than a hundred queued polls. The flag remembers that at least
    // one of the coalesced wakes came from the file, so a backup wake landing on top of
    // a file wake cannot downgrade it into a maybe.
    let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let pending = fileEventPending

    if let databasePath {
      let watcher = DatabaseFileWatcher(
        databasePath: databasePath,
        onChange: {
          pending.withLock { $0 = true }
          wake.yield(())
        },
        logger: logger
      )
      watcher.start()
      self.watcher = watcher
      if watcher.watchedPaths.isEmpty {
        logger.warning(
          "chat.db could not be watched; relying on the backup pass",
          metadata: ["path": .string(databasePath)])
      }
    }

    let floor = configuration.pollInterval
    let backup = configuration.backupInterval

    // The seeding tick. Nothing has been read yet, so the backup check ticks.
    wake.yield(())

    pollTask?.cancel()
    pollTask = Task { [weak self] in
      let timer = Task {
        while !Task.isCancelled {
          try? await Task.sleep(for: backup)
          wake.yield(())
        }
      }
      defer {
        timer.cancel()
        wake.finish()
      }

      for await _ in wakes {
        if Task.isCancelled { break }
        guard let self else { break }
        let fromFile = pending.withLock { flag -> Bool in
          let was = flag
          flag = false
          return was
        }
        do {
          if !fromFile {
            await self.rearmWatcher()
            guard await self.hasCommittedSinceLastTick() else { continue }
          }
          let changes = try await self.tick()
          if !changes.isEmpty { continuation.yield(changes) }
        } catch {
          await self.log(error)
        }
        // Floor between ticks. Without it a chatty conversation queries continuously.
        try? await Task.sleep(for: floor)
      }
      continuation.finish()
    }

    return stream
  }

  public func stop() {
    pollTask?.cancel()
    pollTask = nil
    watcher?.stop()
    watcher = nil
    fileEventPending.withLock { $0 = false }
  }

  private func log(_ error: any Error) {
    logger.warning("Poll failed", metadata: ["error": .string(String(describing: error))])
  }

  private func rearmWatcher() {
    watcher?.armMissing()
  }

  /// The backup question: has any connection committed since the last tick read its token?
  ///
  /// Fails OPEN. If SQLite cannot answer, the tick runs — a wasted query every 30 seconds
  /// is nothing, and a detector that stops looking is the worst outcome there is.
  func hasCommittedSinceLastTick() async -> Bool {
    guard let previous = lastChangeToken else { return true }
    do {
      return try await repository.changeToken() != previous
    } catch {
      logger.warning(
        "Could not read chat.db's change token; querying instead",
        metadata: ["error": .string(String(describing: error))])
      return true
    }
  }

  /// One poll.
  func tick(now: Date = Date()) async throws -> [MessageChange] {
    // Read BEFORE the query, so a commit that lands while the query runs is newer than
    // this token and the next backup pass sees it. Reading after would file it as seen.
    let token = await readChangeToken()
    lastChangeToken = token
    tickCount += 1

    // Wide pass when the interval has elapsed AND something was committed since the last
    // one. A receipt or edit on an old message is a commit like any other, so an unchanged
    // token means the seven-day window would find exactly what it found last time. A
    // failed token read (nil) does not gate: the pass runs on the interval alone.
    let intervalElapsed =
      now.timeIntervalSince(lastReconcile)
      >= configuration.reconcileInterval.seconds
    let committedSinceReconcile =
      token == nil || reconcileToken == nil || token != reconcileToken
    let dueForReconcile = intervalElapsed && committedSinceReconcile
    if dueForReconcile {
      lastReconcile = now
      reconcileToken = token
      reconcileCount += 1
    }

    let lookback =
      dueForReconcile
      ? configuration.reconcileLookback
      : configuration.fastLookback

    // Clamped BEFORE the lookback is applied. A cursor from a week ago plus a 7-day
    // reconcile lookback would query two weeks of history and emit it all as changes.
    let clampedCursor = max(
      cursor,
      now.addingTimeInterval(-configuration.maximumCatchUp.seconds)
    )
    let queryFloor = clampedCursor.addingTimeInterval(-lookback.seconds)

    // Queried by `date` alone — the only indexed timestamp — and filtered below. An OR
    // across date_read/date_delivered/date_edited full-scans `message`.
    //
    // PAGED, and that matters more than it looks. `MessageQuery` caps `limit` at 1000,
    // a single ascending page would mean the 7-day reconcile pass on an install with more
    // than 1000 messages a week only ever examines the OLDEST 1000 in the window, forever.
    // Read receipts, delivered flags and edits on anything newer would never be detected,
    // and the symptom is "read receipts stop working after half an hour" on exactly the
    // busiest accounts. The fast pass hides it, because its 30-minute window rarely holds
    // 1000 messages.
    let candidates = try await fetchWindow(after: queryFloor)

    var changes: [MessageChange] = []
    for message in candidates {
      let fingerprint = fingerprint(of: message)
      guard let previous = seen[message.guid] else {
        seen[message.guid] = fingerprint
        // Only NEW if it actually falls inside the window. The lookback deliberately
        // reaches back past the cursor to catch updates, so most of what it returns
        // is old and already delivered.
        let messageDate = message.date?.date ?? .distantPast
        if messageDate >= clampedCursor.addingTimeInterval(-configuration.overlap.seconds) {
          changes.append(
            MessageChange(message: message, isNew: true, changedFields: [])
          )
        }
        continue
      }

      let changed = Self.difference(from: previous, to: fingerprint)
      if !changed.isEmpty {
        seen[message.guid] = fingerprint
        changes.append(
          MessageChange(message: message, isNew: false, changedFields: changed)
        )
      }
    }

    cursor = now.addingTimeInterval(-configuration.overlap.seconds)
    return changes
  }

  private func readChangeToken() async -> Int? {
    do {
      return try await repository.changeToken()
    } catch {
      logger.warning(
        "Could not read chat.db's change token",
        metadata: ["error": .string(String(describing: error))])
      return nil
    }
  }

  /// Every message in the window, a page at a time.
  ///
  /// Bounded by `maximumWindowPages` rather than run to exhaustion: the reconcile window
  /// is seven days, and on first run against a large archive that is an unbounded read on
  /// the main path. Hitting the bound is logged, because it means the window is not being
  /// fully examined and that is worth knowing rather than guessing at.
  private func fetchWindow(after floor: Date) async throws -> [IMessageRow] {
    var collected: [IMessageRow] = []
    var offset = 0

    for page in 0..<Self.maximumWindowPages {
      let batch = try await repository.messages(
        MessageRepository.MessageQuery(
          after: floor,
          limit: Self.pageSize,
          offset: offset,
          ascending: true,
          includeAttachments: false
        )
      )
      collected.append(contentsOf: batch)
      // A short page is the last page.
      if batch.count < Self.pageSize { return collected }
      offset += batch.count

      if page == Self.maximumWindowPages - 1 {
        logger.warning(
          "Change detection window is larger than the page budget",
          metadata: [
            "examined": .stringConvertible(collected.count),
            "since": .string(String(describing: floor)),
          ])
      }
    }
    return collected
  }

  /// The repository's own ceiling. Asking for more is silently clamped, so matching it
  /// keeps the "a short page is the last page" test honest.
  static let pageSize = 1000
  /// 20 pages — 20,000 messages — per tick. Enough for any real seven-day window, and a
  /// hard stop against a first run over a decade of history.
  static let maximumWindowPages = 20

  private func fingerprint(of message: IMessageRow) -> MessageFingerprint {
    MessageFingerprint(
      date: message.date?.rawValue,
      dateRead: message.dateRead?.rawValue,
      dateDelivered: message.dateDelivered?.rawValue,
      datePlayed: message.datePlayed?.rawValue,
      dateEdited: message.dateEdited?.rawValue,
      dateRetracted: message.dateRetracted?.rawValue,
      didNotifyRecipient: message.didNotifyRecipient,
      error: message.error
    )
  }

  static func difference(
    from previous: MessageFingerprint,
    to current: MessageFingerprint
  ) -> Set<MessageField> {
    var fields: Set<MessageField> = []
    if previous.dateDelivered != current.dateDelivered { fields.insert(.delivered) }
    if previous.dateRead != current.dateRead { fields.insert(.read) }
    if previous.datePlayed != current.datePlayed { fields.insert(.played) }
    if previous.dateEdited != current.dateEdited { fields.insert(.edited) }
    if previous.dateRetracted != current.dateRetracted { fields.insert(.retracted) }
    if previous.error != current.error { fields.insert(.error) }
    // One-way only: false -> true is the notification actually firing. The reverse would
    // be Apple rewriting history, and treating it as a change emits a spurious update.
    if current.didNotifyRecipient == true && previous.didNotifyRecipient != true {
      fields.insert(.notifiedRecipient)
    }
    return fields
  }

  /// Seeds the cache so a restart does not re-announce everything already delivered.
  public func prime(with messages: [IMessageRow]) {
    for message in messages {
      seen[message.guid] = fingerprint(of: message)
    }
  }

  public var trackedCount: Int { seen.count }
}
