//  ChangeDetector
//  Watches chat.db and turns file activity into message change events.
//
//  Two signals, in a fixed order of trust:
//
//    1. PRIMARY: kqueue vnode notifications on chat.db and its -wal sidecar, through
//       `DispatchSource`, on descriptors this process holds open. The kernel delivers them
//       directly; nothing is coalesced by a daemon or delayed by a poll. A write to the WAL
//       wakes the detector within the debounce, and that is where every message normally
//       arrives from.
//    2. BACKUP: every 30 seconds, `PRAGMA data_version`. SQLite bumps it on the reading
//       connection whenever any other connection commits, and answering costs a read of the
//       WAL index in shared memory: microseconds, no disk, no file-system event required.
//       Unchanged means nothing was committed and NO query runs. Changed means the watcher
//       missed something: a descriptor gone stale, a sidecar that did not exist at startup,
//       events that stopped being delivered, and the query runs then.
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
//      skipped when nothing has been committed since the last one: a receipt is a commit.
//    - Querying by `date` and filtering the other timestamps in memory. `date` is the only
//      one of them with an index in Apple's schema (and we cannot add one) so an OR across
//      all of them full-scans `message`, which is the worst case on the old hardware this
//      targets.
//    - The >24h clamp, so a machine that slept for a week does not replay a week of history
//      as new messages on wake.
//
//  The same tick also reads `chat.last_read_message_timestamp`, which is how
//  `chat-read-status-changed` is detected: nothing else reports a chat being read on this Mac
//  or on another device. The injected helper does not; `handleReadStatusForChat:` is the
//  outbound mark-read call, not an observer. See `ChatReadLedger`.
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

// MARK: - Change detection

public struct ChangeDetectorConfiguration: Sendable {
  /// Floor between two ticks, and the debounce on file events. Fixed at 500ms rather than
  /// a setting: below that a busy conversation produces more queries than messages, and
  /// above it the floor is latency added to every message during a burst.
  public var pollInterval: Duration
  /// How often the backup pass asks SQLite whether anything was committed. It is a
  /// shared-memory read, not a query, so the cost of the interval is latency in the one
  /// case the file watcher missed something, not CPU.
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
  /// How many unseen arrivals in ONE tick still count as news rather than as a sync.
  ///
  /// The discriminator the date window could not be. An outage backlog and an iCloud
  /// backfill are indistinguishable by age — a message sent two hours ago and delivered
  /// now looks identical either way — but they differ by an order of magnitude in VOLUME,
  /// and volume is also what the rule is really protecting against: not old notifications,
  /// but a thousand of them at once.
  ///
  /// Above this, the whole batch is cached silently and logged. A cliff rather than a
  /// truncation, deliberately: announcing the first 100 of 5,000 would be a notification
  /// flood AND a silent loss of the other 4,900, which is worse than either alone.
  public var maximumAnnouncedPerTick: Int

  public init(
    pollInterval: Duration = .milliseconds(500),
    backupInterval: Duration = .seconds(30),
    fastLookback: Duration = .seconds(1800),
    reconcileLookback: Duration = .seconds(604_800),
    reconcileInterval: Duration = .seconds(300),
    overlap: Duration = .seconds(30),
    maximumCatchUp: Duration = .seconds(86_400),
    maximumAnnouncedPerTick: Int = 100
  ) {
    self.pollInterval = max(pollInterval, .milliseconds(500))
    self.backupInterval = backupInterval
    self.fastLookback = fastLookback
    self.reconcileLookback = reconcileLookback
    self.reconcileInterval = reconcileInterval
    self.overlap = overlap
    self.maximumCatchUp = maximumCatchUp
    self.maximumAnnouncedPerTick = max(1, maximumAnnouncedPerTick)
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

/// Everything one tick found worth saying.
///
/// One value rather than a second stream, because both halves come from the same commit and
/// the same `PRAGMA data_version` gate: a consumer that read them separately could see a chat
/// marked read before the message that was read in it.
public struct ChangeBatch: Sendable {
  public let messages: [MessageChange]
  /// Chats whose `last_read_message_timestamp` moved forward, oldest read first.
  public let chatReads: [ChatReadMark]

  public init(messages: [MessageChange] = [], chatReads: [ChatReadMark] = []) {
    self.messages = messages
    self.chatReads = chatReads
  }

  public var isEmpty: Bool { messages.isEmpty && chatReads.isEmpty }
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
  /// What the stream's backup timer, floor and re-check sleep on. Injected so a test of the
  /// stream advances time rather than waiting out intervals; the default is the wall clock.
  /// `tick(now:)` takes its time as a parameter and does not read this.
  private let clock: any Clock<Duration>

  /// GUID -> the timestamps we last saw, so a change is detected by comparison rather than
  /// by trusting the query. Bounded: an unbounded map here is one of the leaks the current
  /// server has been patching.
  private var seen: BoundedCache<String, MessageFingerprint>

  /// The date the next fast pass looks back from: the last tick, less `overlap`.
  private var cursor: Date
  /// Which rows have been examined. See `ArrivalMark`.
  private var arrivals = ArrivalMark()
  /// When each recently read chat was last read. See `ChatReadLedger`.
  private var chatReads = ChatReadLedger()
  /// What SQLite said had been committed, and when the wide pass last ran. See
  /// `CommitLedger`.
  private var commits = CommitLedger()
  private var watcher: DatabaseFileWatcher?
  /// Cancelled with the detector, so a service that drops its detector on restart takes the
  /// poll with it rather than leaving it to wake once more on the backup timer.
  private let pollTask = OwnedTask()
  /// Set by the file watcher, cleared by the loop. Distinguishes a wake the watcher raised
  /// (query unconditionally) from a backup wake (ask SQLite first), and survives the two
  /// being coalesced into one.
  private nonisolated let wakeFlags = OSAllocatedUnfairLock(initialState: WakeFlags())

  /// The highest ROWID examined. Internal rather than private so the re-baseline test can
  /// observe the one thing the guard changes. Nothing outside this module can see it.
  var highWaterRowID: Int64 { arrivals.rowID }
  private var hasBaseline: Bool { arrivals.hasBaseline }
  private var lastTickSawCommit: Bool { commits.lastTickSawCommit }

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
    /// watcher: it is the race the re-check exists for.
    var recheck = false
  }

  /// Backup passes in a row that found a commit no file event announced. At this many the
  /// watcher is deaf (a stale descriptor, events that stopped being delivered) and is
  /// torn down and re-armed rather than left to the backup pass forever.
  static let deafWatcherThreshold = 3

  public init(
    repository: MessageRepository,
    configuration: ChangeDetectorConfiguration = ChangeDetectorConfiguration(),
    startingFrom: Date = Date(),
    // At least the reconcile window. A cache smaller than the window evicts and
    // re-learns the same rows on every wide pass, and every fingerprint it forgets is an
    // update it can no longer detect.
    //
    // MEASURED, not guessed. The comment here used to say "20,000 rows of fingerprints is
    // a few megabytes" and that number was what justified the capacity: it is 756 bytes an
    // entry, so 25,000 of them is 18.5MB -- a third of the whole stated idle budget, in one
    // always-populated cache, on the always-on path. The fingerprint itself is only 104 of
    // those bytes; the rest is the GUID string and the cache's own bookkeeping, which is
    // why packing the fingerprint is not the fix and is not attempted.
    //
    // The capacity is now DERIVED rather than invented: `maximumWindowPages * pageSize` is
    // the most rows one reconcile pass can produce, by construction, so it is exactly the
    // number that cannot be evicted mid-pass. The far larger saving is that `trim()` is now
    // called (see `tick`), so a server that has been up for weeks holds the last seven days
    // rather than everything it has ever seen: 1,068 rows on this Mac, against the 20,000
    // ceiling.
    cacheCapacity: Int = ChangeDetector.defaultCacheCapacity,
    clock: any Clock<Duration> = ContinuousClock(),
    logger: Logger = Logger(label: "bluebubbles.change-detector")
  ) {
    self.repository = repository
    self.configuration = configuration
    self.clock = clock
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
  public func changes(watching databasePath: String? = nil) -> AsyncStream<ChangeBatch> {
    let (stream, continuation) = AsyncStream<ChangeBatch>.makeStream(
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
    let clock = self.clock

    // The seeding tick. Nothing has been read yet, so the backup check ticks.
    wake.yield(())

    pollTask.run { [weak self] in
      let timer = Task {
        while !Task.isCancelled {
          try? await clock.sleep(for: backup)
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
              // Not on the seeding tick: nothing has been read yet, so "a commit the
              // watcher missed" would describe every startup.
              if await self.hasBaseline {
                self.logger.debug(
                  "Backup pass found a commit the watcher did not announce",
                  metadata: [
                    "count": .stringConvertible(unannouncedCommits),
                    "threshold": .stringConvertible(Self.deafWatcherThreshold),
                  ])
              }
              if unannouncedCommits >= Self.deafWatcherThreshold, await self.resetWatcher() {
                unannouncedCommits = 0
              }
            }
          }
          let batch = try await self.tick()
          if !batch.isEmpty { continuation.yield(batch) }

          // kqueue reports the WAL write before SQLite publishes the commit to readers,
          // so a file wake can arrive a moment early and the query sees nothing. One
          // re-check after the floor catches that, instead of leaving it to the backup
          // pass thirty seconds later. Bounded: a re-check that finds nothing does not
          // schedule another.
          if wakeFlags.fromFile, await !self.lastTickSawCommit {
            Task {
              try? await clock.sleep(for: floor + .milliseconds(250))
              flags.withLock { $0.recheck = true }
              wake.yield(())
            }
          }
        } catch {
          await self.log(error)
        }
        // Floor between ticks. Without it a chatty conversation queries continuously.
        try? await clock.sleep(for: floor)
      }
      continuation.finish()
    }

    return stream
  }

  public func stop() async {
    await pollTask.stop()
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
  /// Fails OPEN. If SQLite cannot answer, the tick runs: a wasted query every 30 seconds
  /// is nothing, and a detector that stops looking is the worst outcome there is.
  func hasCommittedSinceLastTick() async -> Bool {
    guard let previous = commits.lastToken else { return true }
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
  ///
  /// In four steps, each its own function: decide what this pass reads (`plan`), read it
  /// (`examine`, after `rebaselineIfReplaced`), decide what is news (`classify`), and say so
  /// (`announce`). The bookkeeping between them is ordered, and the order is the behaviour:
  /// the token is read before anything else, the wide pass is marked done only once its
  /// window was read, `classify` judges against the mark as it stood BEFORE this tick, and
  /// the mark then moves over everything examined, announced or not.
  func tick(now: Date = Date()) async throws -> ChangeBatch {
    // Read BEFORE the query, so a commit that lands while the query runs is newer than
    // this token and the next backup pass sees it. Reading after would file it as seen.
    let token = await readChangeToken()
    commits.begin(with: token)
    tickCount += 1

    // The fingerprint cache has a seven-day TTL, and only a sweep honours it: without one,
    // only the count cap ever reclaimed, and a quiet server held every fingerprint it had
    // ever taken for the life of the process. Once in a while rather than every tick,
    // because it is a scan of the whole cache and a tick can be half a second apart.
    if tickCount % Self.ticksBetweenTrims == 0 { seen.trim() }

    let pass = plan(now: now, token: token)
    let candidates: [MessageFingerprintRow]
    let readMarks: [ChatReadMark]
    do {
      try await rebaselineIfReplaced(pass)
      (candidates, readMarks) = try await examine(pass)
    } catch {
      // Nothing was examined, so nothing was seen: forget the token so the next backup
      // pass retries instead of waiting for a further commit, and leave the wide pass
      // due. A tick that fails must cost nothing but the retry.
      commits.forgetToken()
      throw error
    }
    // Bookkeeping only once the window was actually read. Marking the wide pass done
    // before its query ran would let a transient failure (a busy lock during a checkpoint)
    // silently defer it by a full interval.
    if pass.isReconcile {
      commits.markReconciled(at: now, token: token)
      reconcileCount += 1
    }

    let pending = classify(candidates, now: now)
    let advancedReads = chatReads.advance(over: readMarks, floor: pass.chatReadFloor)

    // The mark moves over everything EXAMINED, announced or not, so a row cached silently
    // is not re-offered as new on the next tick.
    arrivals.advance(over: candidates)
    cursor = now.addingTimeInterval(-configuration.overlap.seconds)

    return try await announce(
      pending, chatReads: advancedReads, examined: candidates.count, pass: pass)
  }

  /// What one tick reads, decided before anything is read.
  private struct Pass {
    /// The seven-day pass rather than the 30-minute one.
    let isReconcile: Bool
    /// The `date` floor of the update query.
    let floor: Date
    /// The floor of the chat-read query. It never falls; see `ChatReadLedger`.
    let chatReadFloor: Date

    var label: Logger.MetadataValue { .string(isReconcile ? "reconcile" : "fast") }
  }

  /// Chooses the window: wide or fast, and from where.
  private func plan(now: Date, token: Int?) -> Pass {
    // Wide pass when the interval has elapsed AND something was committed since the last
    // one. A receipt or edit on an old message is a commit like any other, so an unchanged
    // token means the seven-day window would find exactly what it found last time.
    let isReconcile = commits.isReconcileDue(
      now: now, token: token, interval: configuration.reconcileInterval)
    let lookback = isReconcile ? configuration.reconcileLookback : configuration.fastLookback

    // Clamped BEFORE the lookback is applied. A cursor from a week ago plus a 7-day
    // reconcile lookback would query two weeks of history and emit it all as changes.
    let clampedCursor = max(
      cursor,
      now.addingTimeInterval(-configuration.maximumCatchUp.seconds)
    )
    if clampedCursor > cursor {
      logger.debug(
        "Catch-up window clamped; older history is cached rather than announced",
        metadata: [
          "skippedHours": .stringConvertible(
            Int(clampedCursor.timeIntervalSince(cursor) / 3600))
        ])
    }
    return Pass(
      isReconcile: isReconcile, floor: clampedCursor.addingTimeInterval(-lookback.seconds),
      chatReadFloor: chatReads.floor(
        proposing: clampedCursor.addingTimeInterval(-configuration.fastLookback.seconds)))
  }

  /// Resets the arrival mark when chat.db's ROWIDs have gone backwards.
  ///
  /// A replaced `chat.db` (a restore, a rebuild, a migration) reassigns ROWIDs from 1, so
  /// a mark carried over from the old file sits above every row in the new one and would
  /// silence the detector completely and permanently. Checked on the reconcile pass rather
  /// than every tick: it is 0.0027 ms, but so is every other thing that used to be "cheap
  /// enough to do twice a second".
  ///
  /// A read that FAILS fails the tick, like the queries in `examine`. Swallowing it would
  /// skip the one guard against a silenced detector for a whole reconcile interval with
  /// nothing said.
  private func rebaselineIfReplaced(_ pass: Pass) async throws {
    guard pass.isReconcile, arrivals.rowID > 0 else { return }
    guard let maximum = try await repository.maximumMessageRowID(), maximum < arrivals.rowID
    else { return }
    logger.warning(
      "chat.db ROWIDs went backwards; re-baselining arrival tracking",
      metadata: [
        "mark": .stringConvertible(arrivals.rowID),
        "maximum": .stringConvertible(maximum),
      ])
    arrivals.reset()
    // The ROWIDs it is keyed on now name different chats.
    chatReads.reset()
  }

  /// The fingerprints this pass examines.
  ///
  /// Fingerprints only (ROWID, GUID and the eight fields that can move), keyset-paged.
  /// The full row, with its attributed-body and payload blobs, is fetched afterwards for
  /// just the rows that changed. Decoding every row in the window to compare eight numbers
  /// was most of what a tick cost, and on the reconcile pass that was up to 20,000 rows.
  ///
  /// TWO QUERIES, by the two questions they answer, never one disjunction of them:
  ///
  ///   arrivals  ROWID > high-water   what landed since the last look, at any sent time
  ///   updates   date  > pass.floor   receipts and edits on rows already delivered
  ///
  /// The arrival query is what makes an outage backlog visible; the date query is what
  /// makes a read receipt on an older message visible, and a ROWID cannot see that because
  /// an update does not change one. Merging them with `OR` costs the index seek and turns
  /// a 0.005 ms tick into 12.478 ms; see `MessageRepository.messageFingerprints(afterRowID:)`.
  ///
  /// The chat-read query rides along, and a failure of it fails the tick like the other two:
  /// a tick that read the messages and not the chats would advance past a read it never saw.
  private func examine(
    _ pass: Pass
  ) async throws -> (messages: [MessageFingerprintRow], chatReads: [ChatReadMark]) {
    async let landed = fetchArrivals(afterRowID: arrivals.rowID)
    async let moved = fetchWindow(after: pass.floor)
    async let read = repository.chatReadMarks(readAfter: pass.chatReadFloor)
    return (try await merge(landed, moved), try await read)
  }

  /// What the examined rows mean: new, updated, or nothing to say.
  private func classify(_ candidates: [MessageFingerprintRow], now: Date) -> [Pending] {
    // NEW means "arrived since the last look, and not ancient history": ROWID above the
    // high-water mark AND dated within `maximumCatchUp`.
    //
    // The two clauses do different jobs, and one window cannot do both. The ROWID mark
    // answers "have I already delivered this", which is what stops a re-announce; the date
    // bound answers "is this worth announcing at all", which is what stops an iCloud restore
    // of years of history becoming years of notifications. Conflated into a single
    // 30-minute window, the second job set the limit for the first, so a message sent 31
    // minutes before it landed was treated as history.
    //
    // A 24-hour date bound is only safe BECAUSE of the ROWID clause: without it, a 24-hour
    // date window would re-announce a day of messages on every restart.
    let newFloor = now.addingTimeInterval(-configuration.maximumCatchUp.seconds)
    let pending = compare(candidates, newFloor: newFloor, aboveRowID: arrivals.rowID)

    // A burst this large is a sync, not an outage.
    //
    // Age cannot tell those apart (a message sent two hours ago and delivered now looks
    // identical whether the Mac was offline or iCloud is restoring a device) but volume
    // can, and volume is what the rule is actually protecting: not old notifications, but
    // a thousand at once. So the whole batch is demoted to history, and every row is still
    // CACHED, so a later receipt on any of them is reported as an update.
    let announcements = pending.filter(\.isNew).count
    guard announcements > configuration.maximumAnnouncedPerTick else { return pending }
    logger.warning(
      "Too many new messages at once to be an outage; cached as history rather than announced",
      metadata: [
        "new": .stringConvertible(announcements),
        "limit": .stringConvertible(configuration.maximumAnnouncedPerTick),
      ])
    return pending.filter { !$0.isNew }
  }

  /// Hydrates and returns what is worth saying, unless this is the silent first pass.
  private func announce(
    _ pending: [Pending], chatReads: [ChatReadMark], examined: Int, pass: Pass
  ) async throws -> ChangeBatch {
    // The baseline. Everything examined went into the cache; none of it is announced. That
    // includes the chats: one read before startup is history, as a message is.
    guard arrivals.hasBaseline else {
      arrivals.hasBaseline = true
      logger.info(
        "Cached the chat.db baseline; nothing already present is announced",
        metadata: [
          "rows": .stringConvertible(examined),
          "chatReadCount": .stringConvertible(self.chatReads.count),
        ])
      return ChangeBatch()
    }
    guard !pending.isEmpty || !chatReads.isEmpty else {
      // Trace, not debug: this is every backup pass and every early file wake, twice a
      // minute on a quiet Mac, and the line that says a change WAS found is the one a
      // reader at debug is after.
      logger.trace(
        "chat.db tick found nothing",
        metadata: ["examined": .stringConvertible(examined), "pass": pass.label])
      return ChangeBatch()
    }
    logger.debug(
      "chat.db changes detected",
      metadata: [
        "new": .stringConvertible(pending.filter(\.isNew).count),
        "updated": .stringConvertible(pending.filter { !$0.isNew }.count),
        "chatReadCount": .stringConvertible(chatReads.count),
        "examined": .stringConvertible(examined),
        "pass": pass.label,
        "tick": .stringConvertible(tickCount),
      ])
    return ChangeBatch(messages: try await hydrate(pending), chatReads: chatReads)
  }

  /// Forces the mark, so the re-baseline guard can be exercised without replacing a file
  /// on disk mid-test. Internal; `@testable` is the only way to reach it.
  func setHighWater(_ rowID: Int64) { arrivals.rowID = rowID }

  /// A row the fingerprint pass found new or changed, before its full row is fetched.
  private struct Pending {
    let rowID: Int64
    let isNew: Bool
    let changedFields: Set<MessageField>
  }

  /// Holds each candidate against the fingerprint last seen for its GUID, updating the
  /// cache as it goes, and returns the rows that are new inside the window or have moved.
  private func compare(
    _ candidates: [MessageFingerprintRow],
    newFloor: Date,
    aboveRowID highWater: Int64
  ) -> [Pending] {
    var pending: [Pending] = []
    for candidate in candidates {
      let fingerprint = candidate.fingerprint
      guard let previous = seen[candidate.guid] else {
        seen[candidate.guid] = fingerprint
        // Both clauses, and both are load-bearing. The date reach of the reconcile pass is
        // seven days, so most of what it returns is old and already delivered: the ROWID
        // test is what rejects that. The date test is what rejects a backfill, whose rows
        // are genuinely above the mark and genuinely should not be announced.
        let messageDate = fingerprint.date?.date ?? .distantPast
        if candidate.rowID > highWater && messageDate >= newFloor {
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
    return pending
  }

  /// Hydrates only what changed. The stored fingerprint is the one that was compared, so
  /// a row that moved again between the two queries is announced with its newer state
  /// now and once more, as an update, on the next tick; never missed. A row that
  /// vanished in between is dropped here; it was real when fingerprinted and is gone.
  private func hydrate(_ pending: [Pending]) async throws -> [MessageChange] {
    guard !pending.isEmpty else { return [] }
    let rows = try await repository.messages(rowIDs: pending.map(\.rowID))
    let byRowID = Dictionary(rows.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
    if rows.count < pending.count {
      logger.debug(
        "Rows vanished between fingerprint and fetch",
        metadata: ["dropped": .stringConvertible(pending.count - rows.count)])
    }
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
  /// Everything inserted above the high-water mark, paged the same way the window is.
  ///
  /// Unpaged this would be unbounded: the baseline tick starts from ROWID 0, and on this
  /// developer's Mac that is 421,941 rows. The page budget is the same one the date window
  /// uses, so a backlog larger than it is truncated and logged rather than loaded whole.
  private func fetchArrivals(afterRowID rowID: Int64) async throws -> [MessageFingerprintRow] {
    var collected: [MessageFingerprintRow] = []
    var mark = rowID

    for page in 0..<Self.maximumWindowPages {
      let batch = try await repository.messageFingerprints(afterRowID: mark, limit: Self.pageSize)
      collected.append(contentsOf: batch)
      if batch.count < Self.pageSize { return collected }
      guard let last = batch.last else { return collected }
      mark = last.rowID

      if page == Self.maximumWindowPages - 1 {
        logger.warning(
          "Arrival backlog is larger than the page budget",
          metadata: [
            "examined": .stringConvertible(collected.count),
            "afterRowID": .stringConvertible(rowID),
          ])
      }
    }
    return collected
  }

  /// The two queries' results as one list, each row once.
  ///
  /// They overlap: a message that arrived in the last few minutes satisfies both. Keyed by
  /// ROWID rather than GUID because that is what both queries agree on and what `compare`
  /// and the high-water mark are keyed on.
  private func merge(
    _ arrivals: [MessageFingerprintRow],
    _ updates: [MessageFingerprintRow]
  ) -> [MessageFingerprintRow] {
    var byRowID: [Int64: MessageFingerprintRow] = [:]
    byRowID.reserveCapacity(arrivals.count + updates.count)
    for row in updates { byRowID[row.rowID] = row }
    for row in arrivals { byRowID[row.rowID] = row }
    // Oldest first, the order both queries promise and `hydrate` relies on.
    return byRowID.values.sorted { $0.rowID < $1.rowID }
  }

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
      guard let last = batch.last, let lastDate = last.fingerprint.date else { return collected }
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
  /// 20 pages (20,000 fingerprints) per tick. Enough for any real seven-day window, and
  /// a hard stop against a first run over a decade of history.
  static let maximumWindowPages = 20

  /// The most fingerprints one reconcile pass can produce, which is what the cache must hold
  /// without evicting mid-pass. Derived rather than chosen; see `init`.
  public static let defaultCacheCapacity = maximumWindowPages * pageSize

  /// How many ticks between TTL sweeps of the fingerprint cache.
  ///
  /// A tick is `pollInterval` apart at its fastest (500ms), so this is about a minute. The
  /// sweep is O(entries) and the TTL is seven days: sweeping more often would cost a scan to
  /// find nothing.
  static let ticksBetweenTrims = 120

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

  /// Seeds the cache with rows outside the first tick's window. The first tick is itself
  /// silent, so this is only needed for rows it would not examine.
  public func prime(with messages: [IMessageRow]) {
    for message in messages {
      seen[message.guid] = MessageFingerprint(message)
    }
  }

  public var trackedCount: Int { seen.count }
}

// MARK: - Detector state

extension ChangeDetector {

  /// How far arrivals have been examined, and whether the silent first pass has run.
  ///
  /// One value because the two move together: a replaced chat.db resets both, so the pass
  /// that notices re-learns the new file without announcing it.
  struct ArrivalMark {
    /// The highest ROWID this detector has examined.
    ///
    /// The half of "is this new" that a date window cannot answer. A ROWID is assigned when
    /// Messages INSERTS the row; the date is when the sender sent it. An outage separates
    /// the two, and a rule of "new if sent within the last 30 minutes" silently caches every
    /// message of a longer outage's backlog however recently it landed.
    ///
    /// It is also what stops a re-announce, and more robustly than any window: `seen` is a
    /// bounded cache with a 7-day TTL, so an evicted GUID looks unseen again, while its
    /// ROWID stays below this mark for ever. That is what lets the date rule be as wide as
    /// `maximumCatchUp` without re-announcing history.
    var rowID: Int64 = 0
    /// Whether the first tick has run. That tick caches everything in its window and
    /// announces nothing: on startup or restart, what is already in chat.db is history, not
    /// news. A client that missed it syncs on its own; re-announcing the last half hour on
    /// every restart is the more visible failure, and the one users report.
    var hasBaseline = false

    mutating func reset() {
      rowID = 0
      hasBaseline = false
    }

    mutating func advance(over candidates: [MessageFingerprintRow]) {
      rowID = max(rowID, candidates.map(\.rowID).max() ?? rowID)
    }
  }

  /// When each chat in the read window was last read, and where that window starts.
  ///
  /// A chat is announced when its `last_read_message_timestamp` INCREASES. A value that goes
  /// backwards is not a read, and the higher one is kept, so a later read has to pass it.
  ///
  /// The window's floor only ever rises (`floor(proposing:)`), and that is what makes a chat
  /// with no entry safe to announce: the baseline cached every chat in the window, and with a
  /// floor that never falls, the only way into the window afterwards is for the chat's value
  /// to move past it. Recomputed per tick instead, anything that lowered it would offer every
  /// chat it uncovered as unseen: a wall clock stepped backwards, or the reconcile pass's
  /// seven-day lookback. The proposal is the fast lookback on every tick, so the query
  /// returns the last half hour's reads and never a week of them.
  ///
  /// Bounded by construction: an entry that falls below the floor is dropped, since it can
  /// only return by moving past the floor, which announces it anyway. What is held is the
  /// chats read in the last half hour, not every chat on the Mac.
  struct ChatReadLedger {
    private var marks: [Int64: AppleTimestamp] = [:]
    private var heldFloor: Date = .distantPast

    var count: Int { marks.count }

    /// The floor this tick reads from: `proposed`, unless an earlier tick read from higher.
    func floor(proposing proposed: Date) -> Date { max(heldFloor, proposed) }

    /// Records what a tick read, and returns the chats whose read time moved forward.
    mutating func advance(over rows: [ChatReadMark], floor: Date) -> [ChatReadMark] {
      heldFloor = floor
      var advanced: [ChatReadMark] = []
      for row in rows {
        if let previous = marks[row.rowID], row.lastRead <= previous { continue }
        marks[row.rowID] = row.lastRead
        advanced.append(row)
      }
      marks = marks.filter { ($0.value.date ?? .distantPast) > floor }
      return advanced
    }

    mutating func reset() {
      marks = [:]
      heldFloor = .distantPast
    }
  }

  /// What `PRAGMA data_version` said, and when the wide pass last ran.
  ///
  /// An unknown token, on either side of a comparison, always counts as a commit. A failed
  /// read must make the detector look, never make it skip.
  struct CommitLedger {
    /// `data_version` as read at the start of the last tick. Nil until the first tick, and
    /// nil again if the read or the tick failed: either way the backup pass ticks rather
    /// than guesses.
    var lastToken: Int?
    /// `data_version` at the last wide pass. Equal to the current one means no commit
    /// since, so there is nothing for a wide pass to find.
    var reconcileToken: Int?
    var lastReconcile: Date = .distantPast
    /// Whether the last tick's token differed from the one before it: that is, whether
    /// the wake that caused it found a commit. A file wake that found none is re-checked
    /// once.
    var lastTickSawCommit = true

    /// Records the token a tick starts from.
    mutating func begin(with token: Int?) {
      lastTickSawCommit = token == nil || lastToken == nil || token != lastToken
      lastToken = token
    }

    /// A tick that failed examined nothing, so its token must not count as seen.
    mutating func forgetToken() { lastToken = nil }

    /// The interval has elapsed AND something was committed since the last wide pass.
    func isReconcileDue(now: Date, token: Int?, interval: Duration) -> Bool {
      let intervalElapsed = now.timeIntervalSince(lastReconcile) >= interval.seconds
      let committedSince = token == nil || reconcileToken == nil || token != reconcileToken
      return intervalElapsed && committedSince
    }

    mutating func markReconciled(at now: Date, token: Int?) {
      lastReconcile = now
      reconcileToken = token
    }
  }
}
