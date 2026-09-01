//  ChangeDetector
//  Watches chat.db and turns file activity into message change events.
//
//  The algorithm is sound and is kept; the plumbing is replaced. What changes:
//    - fs.watch + MultiFileWatcher becomes DispatchSource file-system observation, which
//      does not miss the -wal writes that carry most of the activity.
//    - The Sema(1) process lock and the @DebounceSubsequentWithWait decorator become actor
//      isolation and a debounced AsyncStream. The decorator keyed its lock by a GLOBAL
//      string, so two instances of the same class shared one lock.
//    - EventCache's linear array scan becomes a GUID-keyed bounded cache.
//
//  What is preserved exactly, because getting it wrong loses messages:
//    - The DUAL LOOKBACK. A 30-minute fast window on every tick (Apple only permits edits
//      within ~15 minutes and unsends within ~2), widening to a full 7 days every 5 minutes
//      to catch read receipts and notification flags on older messages.
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

// MARK: - File watching

/// Watches chat.db and its WAL sidecar.
///
/// The WAL is the one that matters: SQLite in WAL mode appends there and only checkpoints
/// into the main file periodically, so a watcher looking only at `chat.db` sees activity in
/// bursts minutes late. Watching both is what makes delivery feel immediate.
public final class DatabaseFileWatcher: @unchecked Sendable {

  private let paths: [String]
  private var sources: [any DispatchSourceFileSystemObject] = []
  private let queue = DispatchQueue(label: "bluebubbles.chatdb-watch")
  private let onChange: @Sendable () -> Void
  private let logger: Logger

  public init(
    databasePath: String,
    onChange: @escaping @Sendable () -> Void,
    logger: Logger = Logger(label: "bluebubbles.chatdb-watch")
  ) {
    self.paths = [databasePath, databasePath + "-wal", databasePath + "-shm"]
    self.onChange = onChange
    self.logger = logger
  }

  public func start() {
    for path in paths {
      // A missing sidecar is normal — the WAL only exists while there is uncommitted
      // activity — so this is not an error, and the file is picked up on a later
      // restart if it appears.
      let descriptor = open(path, O_EVTONLY)
      guard descriptor >= 0 else { continue }

      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        // .delete and .rename matter because SQLite checkpointing REPLACES the WAL
        // rather than truncating it, which invalidates our descriptor. Without
        // watching for that, the watcher silently goes deaf after the first
        // checkpoint.
        eventMask: [.write, .extend, .delete, .rename, .link],
        queue: queue
      )

      source.setEventHandler { [weak self] in
        guard let self else { return }
        let flags = source.data
        if flags.contains(.delete) || flags.contains(.rename) {
          // Re-open on the next tick. Do not attempt it inline: the replacement
          // file may not exist yet mid-checkpoint.
          self.logger.debug("chat.db sidecar was replaced; re-arming the watcher")
          self.restart()
        }
        self.onChange()
      }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      sources.append(source)
    }
  }

  public func stop() {
    for source in sources { source.cancel() }
    sources.removeAll()
  }

  private func restart() {
    queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
      guard let self else { return }
      self.stop()
      self.start()
    }
  }

  deinit { stop() }
}

// MARK: - Change detection

public struct ChangeDetectorConfiguration: Sendable {
  /// Floor of 500ms. Below that, a busy conversation produces more polls than messages.
  public var pollInterval: Duration
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
    fastLookback: Duration = .seconds(1800),
    reconcileLookback: Duration = .seconds(604_800),
    reconcileInterval: Duration = .seconds(300),
    overlap: Duration = .seconds(30),
    maximumCatchUp: Duration = .seconds(86_400)
  ) {
    self.pollInterval = max(pollInterval, .milliseconds(500))
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
  private var watcher: DatabaseFileWatcher?
  private var pollTask: Task<Void, Never>?

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
  /// `databasePath` arms a file watcher that nudges the loop the moment chat.db or its WAL
  /// is written, so latency is the debounce rather than the poll interval. The interval
  /// remains as a floor and a fallback — file watching can go deaf across a SQLite
  /// checkpoint, and a detector that stops noticing messages is much worse than one that
  /// notices them a second late.
  public func changes(watching databasePath: String? = nil) -> AsyncStream<[MessageChange]> {
    let (stream, continuation) = AsyncStream<[MessageChange]>.makeStream(
      bufferingPolicy: .bufferingNewest(32)
    )

    // Coalesces a burst of file events into one wake. `bufferingNewest(1)` IS the
    // debounce: a hundred WAL writes while a tick is in flight collapse into one
    // pending wake rather than a hundred queued polls.
    let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    if let databasePath {
      let watcher = DatabaseFileWatcher(
        databasePath: databasePath,
        onChange: { wake.yield(()) },
        logger: logger
      )
      watcher.start()
      self.watcher = watcher
    }

    let interval = configuration.pollInterval

    pollTask?.cancel()
    pollTask = Task { [weak self] in
      // Ticks whether or not anything was written, so the fallback holds.
      let timer = Task {
        while !Task.isCancelled {
          try? await Task.sleep(for: interval)
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
        do {
          let changes = try await self.tick()
          if !changes.isEmpty { continuation.yield(changes) }
        } catch {
          await self.log(error)
        }
        // Floor between ticks. Without it a chatty conversation polls continuously.
        try? await Task.sleep(for: interval)
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
  }

  private func log(_ error: any Error) {
    logger.warning("Poll failed", metadata: ["error": .string(String(describing: error))])
  }

  /// One poll.
  func tick(now: Date = Date()) async throws -> [MessageChange] {
    let dueForReconcile =
      now.timeIntervalSince(lastReconcile)
      >= configuration.reconcileInterval.seconds
    if dueForReconcile { lastReconcile = now }

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
    // and this used to take a single ascending page — so on the 7-day reconcile pass an
    // install with more than 1000 messages a week only ever examined the OLDEST 1000 in
    // the window, forever. Read receipts, delivered flags and edits on anything newer
    // than that were never detected, and the symptom was "read receipts stop working
    // after half an hour" on exactly the busiest accounts. The fast pass hid it, because
    // its 30-minute window rarely holds 1000 messages.
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
