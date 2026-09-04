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
  /// Floor between two ticks, and the debounce on file events. Fixed at 500ms rather than
  /// a setting: below that a busy conversation produces more queries than messages, and
  /// above it the floor is latency added to every message during a burst.
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
    pollInterval: Duration = .milliseconds(500),
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
  private nonisolated let wakeFlags = OSAllocatedUnfairLock(initialState: WakeFlags())
  /// Whether the last tick's token differed from the one before it — that is, whether the
  /// wake that caused it found a commit. A file wake that found none is re-checked once.
  private var lastTickSawCommit = true

  /// How many times the table was queried. For tests: the point of the backup pass is that
  /// this does NOT grow while nothing is committed.
  private(set) var tickCount = 0
  private(set) var reconcileCount = 0
  /// How many times the watcher was torn down and re-armed for going deaf.
  private(set) var watcherResets = 0

  struct WakeFlags: Sendable {
    /// The file watcher raised this wake: query unconditionally.
    var fromFile = false
    /// This wake is the one re-check after a file wake that found no commit. It asks
    /// SQLite first like a backup wake, but a commit it finds is not evidence of a deaf
    /// watcher — it is the race the re-check exists for.
    var recheck = false
  }

  struct MessageFingerprint: Sendable {
    let date: Int64?
    let dateRead: Int64?
    let dateDelivered: Int64?
    let datePlayed: Int64?
    let dateEdited: Int64?
    let dateRetracted: Int64?
    let didNotifyRecipient: Bool?
    let error: Int

    init(
      date: Int64?, dateRead: Int64?, dateDelivered: Int64?, datePlayed: Int64?,
      dateEdited: Int64?, dateRetracted: Int64?, didNotifyRecipient: Bool?, error: Int
    ) {
      self.date = date
      self.dateRead = dateRead
      self.dateDelivered = dateDelivered
      self.datePlayed = datePlayed
      self.dateEdited = dateEdited
      self.dateRetracted = dateRetracted
      self.didNotifyRecipient = didNotifyRecipient
      self.error = error
    }

    init(_ row: MessageFingerprintRow) {
      date = row.date?.rawValue
      dateRead = row.dateRead?.rawValue
      dateDelivered = row.dateDelivered?.rawValue
      datePlayed = row.datePlayed?.rawValue
      dateEdited = row.dateEdited?.rawValue
      dateRetracted = row.dateRetracted?.rawValue
      didNotifyRecipient = row.didNotifyRecipient
      error = row.error
    }

    init(_ message: IMessageRow) {
      date = message.date?.rawValue
      dateRead = message.dateRead?.rawValue
      dateDelivered = message.dateDelivered?.rawValue
      datePlayed = message.datePlayed?.rawValue
      dateEdited = message.dateEdited?.rawValue
      dateRetracted = message.dateRetracted?.rawValue
      didNotifyRecipient = message.didNotifyRecipient
      error = message.error
    }
  }

  /// Backup passes in a row that found a commit no file event announced. At this many the
  /// watcher is deaf — a stale descriptor, events that stopped being delivered — and is
  /// torn down and re-armed rather than left to the backup pass forever.
  static let deafWatcherThreshold = 3

  public init(
    repository: MessageRepository,
    configuration: ChangeDetectorConfiguration = ChangeDetectorConfiguration(),
    startingFrom: Date = Date(),
    // At least the reconcile window. A cache smaller than the window evicts and
    // re-learns the same rows on every wide pass, and every fingerprint it forgets is an
    // update it can no longer detect. 20,000 rows of fingerprints is a few megabytes.
    cacheCapacity: Int = 25_000,
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
    let flags = wakeFlags

    if let databasePath {
      let watcher = DatabaseFileWatcher(
        databasePath: databasePath,
        onChange: {
          flags.withLock { $0.fromFile = true }
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

      // Consecutive backup passes that found a commit the watcher never announced.
      var unannouncedCommits = 0

      for await _ in wakes {
        if Task.isCancelled { break }
        guard let self else { break }
        let wakeFlags = flags.withLock { state -> WakeFlags in
          let taken = state
          state = WakeFlags()
          return taken
        }
        do {
          if wakeFlags.fromFile {
            unannouncedCommits = 0
          } else {
            await self.rearmWatcher()
            guard await self.hasCommittedSinceLastTick() else { continue }
            if !wakeFlags.recheck {
              unannouncedCommits += 1
              if unannouncedCommits >= Self.deafWatcherThreshold, await self.resetWatcher() {
                unannouncedCommits = 0
              }
            }
          }
          let changes = try await self.tick()
          if !changes.isEmpty { continuation.yield(changes) }

          // kqueue reports the WAL write before SQLite publishes the commit to readers,
          // so a file wake can arrive a moment early and the query sees nothing. One
          // re-check after the floor catches that, instead of leaving it to the backup
          // pass thirty seconds later. Bounded: a re-check that finds nothing does not
          // schedule another.
          if wakeFlags.fromFile, await !self.lastTickSawCommit {
            Task {
              try? await Task.sleep(for: floor + .milliseconds(250))
              flags.withLock { $0.recheck = true }
              wake.yield(())
            }
          }
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
    wakeFlags.withLock { $0 = WakeFlags() }
  }

  private func log(_ error: any Error) {
    logger.warning("Poll failed", metadata: ["error": .string(String(describing: error))])
  }

  private func rearmWatcher() {
    watcher?.armMissing()
  }

  /// Tears the watcher down and arms it again. Returns false when there is nothing to
  /// reset: a stream started without a path is backup-only by design, and a watcher with
  /// no armed source already warned at startup and is re-tried by every backup pass.
  private func resetWatcher() -> Bool {
    guard let watcher, !watcher.watchedPaths.isEmpty else { return false }
    logger.warning(
      "chat.db commits are arriving without file events; re-arming the watcher",
      metadata: ["watched": .string(watcher.watchedPaths.joined(separator: ", "))])
    watcher.stop()
    watcher.start()
    watcherResets += 1
    return true
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
    // Unknown on either side counts as seen: a failed read must not schedule re-checks.
    lastTickSawCommit = token == nil || lastChangeToken == nil || token != lastChangeToken
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

    // Fingerprints only — ROWID, GUID and the eight fields that can move — queried by
    // `date` alone (the only indexed timestamp) and keyset-paged. The full row, with its
    // attributed-body and payload blobs, is fetched afterwards for just the rows that
    // changed. Decoding every row in the window to compare eight numbers was most of what
    // a tick cost, and on the reconcile pass that was up to 20,000 rows.
    let candidates: [MessageFingerprintRow]
    do {
      candidates = try await fetchWindow(after: queryFloor)
    } catch {
      // Nothing was examined, so nothing was seen: forget the token so the next backup
      // pass retries instead of waiting for a further commit, and leave the wide pass
      // due. A tick that fails must cost nothing but the retry.
      lastChangeToken = nil
      throw error
    }
    // Bookkeeping only once the window was actually read. Marking the wide pass done
    // before its query ran meant a transient failure — a busy lock during a checkpoint —
    // silently deferred it by a full interval.
    if dueForReconcile {
      lastReconcile = now
      reconcileToken = token
      reconcileCount += 1
    }

    struct Pending {
      let rowID: Int64
      let isNew: Bool
      let changedFields: Set<MessageField>
    }
    var pending: [Pending] = []
    let newFloor = clampedCursor.addingTimeInterval(-configuration.overlap.seconds)

    for candidate in candidates {
      let fingerprint = MessageFingerprint(candidate)
      guard let previous = seen[candidate.guid] else {
        seen[candidate.guid] = fingerprint
        // Only NEW if it actually falls inside the window. The lookback deliberately
        // reaches back past the cursor to catch updates, so most of what it returns
        // is old and already delivered.
        let messageDate = candidate.date?.date ?? .distantPast
        if messageDate >= newFloor {
          pending.append(Pending(rowID: candidate.rowID, isNew: true, changedFields: []))
        }
        continue
      }

      let changed = Self.difference(from: previous, to: fingerprint)
      if !changed.isEmpty {
        seen[candidate.guid] = fingerprint
        pending.append(
          Pending(rowID: candidate.rowID, isNew: false, changedFields: changed))
      }
    }

    cursor = now.addingTimeInterval(-configuration.overlap.seconds)
    guard !pending.isEmpty else { return [] }

    // Hydrate only what changed. The stored fingerprint is the one that was compared, so
    // a row that moved again between the two queries is announced with its newer state
    // now and once more, as an update, on the next tick — never missed. A row that
    // vanished in between is dropped here; it was real when fingerprinted and is gone.
    let rows = try await repository.messages(rowIDs: pending.map(\.rowID))
    let byRowID = Dictionary(rows.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
    return pending.compactMap { item in
      byRowID[item.rowID].map {
        MessageChange(message: $0, isNew: item.isNew, changedFields: item.changedFields)
      }
    }
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

  /// Every message fingerprint in the window, a page at a time.
  ///
  /// Bounded by `maximumWindowPages` rather than run to exhaustion: the reconcile window
  /// is seven days, and on first run against a large archive that is an unbounded read on
  /// the main path. Hitting the bound is logged, because it means the window is not being
  /// fully examined and that is worth knowing rather than guessing at.
  private func fetchWindow(after floor: Date) async throws -> [MessageFingerprintRow] {
    var collected: [MessageFingerprintRow] = []
    var resume: MessageRepository.FingerprintCursor?

    for page in 0..<Self.maximumWindowPages {
      let batch = try await repository.messageFingerprints(
        after: floor, resumingFrom: resume, limit: Self.pageSize
      )
      collected.append(contentsOf: batch)
      // A short page is the last page.
      if batch.count < Self.pageSize { return collected }
      // The query excludes NULL dates, so the last row always has one.
      guard let last = batch.last, let lastDate = last.date else { return collected }
      resume = .init(date: lastDate.rawValue, rowID: last.rowID)

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
  /// 20 pages — 20,000 fingerprints — per tick. Enough for any real seven-day window, and
  /// a hard stop against a first run over a decade of history.
  static let maximumWindowPages = 20

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
      seen[message.guid] = MessageFingerprint(message)
    }
  }

  public var trackedCount: Int { seen.count }
}
