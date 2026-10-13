//  MessageSearchIndexService
//  Fills the search index, keeps it current, and removes it when the feature is switched off.
//
//  The index is what makes message text searchable on macOS 26, where `message.text` is empty
//  and the words live in `attributedBody`; `docs/SEARCH.md` has the measurements. This service
//  is the only thing that writes to it.
//
//  THREE THINGS IT DOES NOT DO, each for a reason worth keeping
//
//  **It does not block startup.** The backfill is six seconds of CPU here and an estimated
//  thirty to forty on the Intel Macs this has to run on. `start()` returns as soon as the pump
//  is launched; search reports itself incomplete and falls back to `LIKE` until the backfill
//  finishes, which is degraded rather than blocked.
//
//  **It does not add a poller.** It watches `PRAGMA data_version` — a shared-memory read, not a
//  query — which is the same trick the message watcher's backup pass uses. On a Mac where
//  nothing is being said this costs one PRAGMA a minute and no I/O. Running a second
//  `ChangeDetector` would have been a second fingerprint pass over the same table.
//
//  **It does not depend on the message watcher.** The two touch the same database and nothing
//  else: no shared cursor, no ordering requirement, and — this is the part that matters — no
//  restart coupling. A service that restarted this one would throw away a backfill in progress.
//
//  NOT `GatedService`, deliberately. A gated service that declines is never constructed, and
//  something has to be running to DELETE the index when the switch goes off. So it always
//  starts and reads the switch itself: off means "make sure there is nothing on disk", which is
//  work, not idling.

import BBBuiltIns
import BBCore
import BBIMessage
import BBInterfaces
import BBPersistence
import BBServiceKit
import BBSettings
import Foundation
import Logging

actor MessageSearchIndexService: Service, ConfigurableService {
  static let manifest = BuiltInManifests.messageSearch

  /// Rebuilt from scratch rather than resumed if it dies: the work is seconds and the state
  /// it would resume into is the thing that failed.
  static let restartPolicy = RestartPolicy.backoff(
    base: .seconds(30), max: .seconds(300), attempts: 3
  )

  typealias Host = any ScopedSettingsProviding & LoggerProviding & MessageSourceProviding
    & MessageReindexerPublishing & SearchIndexProviding & HealthChangeReporting

  /// How often the index asks whether anything was committed.
  ///
  /// Sixty seconds, and the cost of the interval is LATENCY rather than CPU: the tick is one
  /// `PRAGMA data_version`, and it does no query at all unless the answer moved. A message
  /// becoming searchable a minute after it arrives is not a delay anybody is waiting on —
  /// the message itself is delivered by a path that has nothing to do with this.
  ///
  /// It is also how long a Rebuild asked for on the settings screen waits before the walk
  /// actually starts. The screen does not LOOK stalled, because the status it renders is
  /// derived from the same flag the request sets — it says "building" at once, and the
  /// count starts climbing within the minute. Waking the pump on demand would need a
  /// continuation raced against this sleep, which is machinery for a button nobody presses
  /// twice.
  static let pollInterval: Duration = .seconds(60)

  /// This instance's interval. The static above is the shipped value, and the protocol's
  /// `init(host:)` always uses it; only the test initialiser below can override it, which
  /// is what lets a test watch a pass happen rather than waiting out a minute.
  private let pollInterval: Duration

  /// This instance's reconcile interval. See the test initialiser.
  private let pruneInterval: Duration

  /// Messages read, decoded and written per pass.
  ///
  /// Five hundred is about seven milliseconds of decoding, which is short enough that a page
  /// need not yield inside itself, and the `await` between pages is where the cooperative
  /// pool gets its thread back. The cursor is saved after every page, so a backfill
  /// interrupted anywhere resumes within one page of where it stopped.
  static let pageSize = 500

  private let scoped: ScopedSettings
  private let logger: Logger
  private let messages: MessageRepository?
  private let store: SearchIndexStore
  private let publisher: any MessageReindexerPublishing
  /// Told whenever `state` moves on its own.
  ///
  /// The registry publishes a health snapshot on every transition IT performs — start, stop,
  /// restart — and this service's most interesting transition is none of those: the backfill
  /// finishing happens inside the pump, seconds to minutes after `start()` returned. Without
  /// this the app shows "building the search index" until something unrelated moves, which
  /// from the user's side is a progress indicator that never completes.
  private let healthReporter: any HealthChangeReporting
  private let pump = OwnedTask()

  /// Every write goes through `setState` so the report cannot be forgotten at one of them.
  private var state: State = .idle

  /// What `health` reports, and what the settings screen will read.
  enum State: Equatable {
    case idle
    case disabled
    case unsupported(reason: String)
    /// `fraction` is how far the walk has got through its `BackfillExtent`, and nil until
    /// the walk has measured one: between `start()` returning and the first page landing.
    case building(indexed: Int, fraction: Double?)
    case ready(indexed: Int)
  }

  /// The rows one backfill has to walk: from the cursor it started at, to the highest ROWID
  /// that existed when it started. What the sidebar's bar measures.
  ///
  /// **The delta, not the table.** A first build starts at zero, and then the two are the
  /// same thing. A build resumed after a crash starts at the cursor it left, and a bar that
  /// opened at 60% would be reporting work a previous process did; what THIS process is doing
  /// is the remaining 40%, and that is what reaches 100% when it finishes. The steady state
  /// indexes what arrives with no extent at all, because four messages a minute is not a
  /// build; see `indexNewMessages`.
  ///
  /// **The ceiling is fixed before the walk.** Messages keep arriving while it runs, and a
  /// ceiling re-read on every page is a bar that reaches 100% and keeps going, which is worse
  /// than no bar. The rows above the fixed ceiling are still walked in the same pass, since
  /// the loop ends on an empty page rather than at the ceiling, and for that tail the bar
  /// sits at 100%.
  ///
  /// **In ROWIDs, not in rows with text**, because ROWIDs are the walk's own unit: the cursor
  /// advances over attachments and tapbacks that never reach the index, and a fraction of
  /// rows-with-text would need that total counted first, which is the scan this service
  /// exists to avoid. Gaps left by deletions make the bar slightly uneven and never wrong.
  struct BackfillExtent: Equatable, Sendable {
    let start: Int64
    let ceiling: Int64

    /// How far a cursor is through this extent, from 0 to 1.
    ///
    /// Clamped at both ends: a cursor past the ceiling is the tail described above, and an
    /// extent with nothing in it is complete rather than a division by zero.
    func fraction(at cursor: Int64) -> Double {
      guard ceiling > start else { return 1 }
      let walked = Double(cursor - start) / Double(ceiling - start)
      return min(max(walked, 0), 1)
    }
  }

  init(host: Host) {
    self.pollInterval = Self.pollInterval
    self.pruneInterval = Self.pruneInterval
    self.scoped = host.scopedSettings(for: Self.manifest)
    self.logger = host.logger
    self.messages = host.messages
    // The container's, NOT a fresh one: the repository reads this same instance.
    self.store = host.searchIndex
    self.publisher = host
    self.healthReporter = host
  }

  /// For tests: the same service over an index somewhere else.
  ///
  /// The two intervals are overridable for the same reason — a test that waited out the
  /// shipped values would take an hour and a minute — and for that reason only. The
  /// protocol's `init(host:)` always takes the shipped ones.
  init(
    host: Host, store: SearchIndexStore,
    pollInterval: Duration = MessageSearchIndexService.pollInterval,
    pruneInterval: Duration = MessageSearchIndexService.pruneInterval
  ) {
    self.pollInterval = pollInterval
    self.pruneInterval = pruneInterval
    self.scoped = host.scopedSettings(for: Self.manifest)
    self.logger = host.logger
    self.messages = host.messages
    self.store = store
    self.publisher = host
    self.healthReporter = host
  }

  /// How often a climbing count is worth waking the app for.
  ///
  /// One second. Below that nobody can read the number anyway, and a report is not free:
  /// `ServiceRegistry.publishHealth` polls EVERY registered service's `health` for each one,
  /// so a single progress tick costs an actor hop per service in the process.
  /// Five seconds, not one. Every report re-renders the sidebar's task row, and on macOS 26
  /// the sidebar is glass: a count that moved once a second re-sampled the glass once a
  /// second for the length of a build, which on a Mac with years of messages is minutes.
  /// A bar that moves every five seconds still reads as moving.
  static let progressReportInterval: Duration = .seconds(5)

  /// When the last `.building` progress report went out.
  private var lastProgressReport: ContinuousClock.Instant?

  /// Moves the state and tells whoever is watching.
  ///
  /// One door, so a new transition cannot be added without the report coming with it. A
  /// no-op when the state has not actually moved.
  ///
  /// **Progress inside `.building` is throttled, transitions never are.** The backfill sets
  /// `.building` once per page — 840 times on the author's 420,000-message database, in
  /// fourteen seconds — and every one of those carries a different count, so equality does
  /// not dedupe them and the original comment here claiming it did was wrong. What a screen
  /// branches on is the transition into and out of building; what it merely displays is the
  /// number. So the transitions always report and the number reports at most once every
  /// `progressReportInterval`.
  ///
  /// The first MEASURED page is a transition too: `.building` without a fraction is a line
  /// of text on Home, and with one it is a row in the sidebar, so the report that adds the
  /// fraction is the one that puts the bar on screen. Held back by the throttle it would
  /// arrive a second late on every build, and on a build shorter than a second, never.
  private func setState(_ next: State) async {
    guard next != state else { return }
    let previous = state
    state = next

    if case .building(_, let nextFraction) = next,
      case .building(_, let previousFraction) = previous,
      (nextFraction == nil) == (previousFraction == nil)
    {
      let now = ContinuousClock.now
      if let last = lastProgressReport, now - last < Self.progressReportInterval { return }
      lastProgressReport = now
    }
    await healthReporter.serviceHealthDidChange(Self.id)
  }

  // MARK: - Lifecycle

  func start() async throws {
    guard await scoped.valueOrDefault(Settings.searchIndexEnabled) else {
      // The switch is off, so the job is to leave nothing behind. Running this on every
      // start rather than only on the change is what makes the promise hold for an install
      // that was switched off while the server was not running.
      try? await store.destroy()
      await setState(.disabled)
      return
    }

    guard let repository = messages else {
      throw ServiceStartupError.unavailable("chat.db is not readable")
    }

    switch try await store.open() {
    case .unsupported(let reason):
      // Not a startup failure: the service has done all it can and the feature reports
      // itself unavailable. Throwing would put a working server into a restart loop over
      // an optional index.
      await setState(.unsupported(reason: reason))
      return
    case .available:
      break
    }

    // The state the FILE says, not "building" on faith. A start over a finished index is the
    // common case (every launch after the first), and the steady-state pass moves to
    // `.ready` only after it adds a message, so reporting `.building` here left Home
    // saying "building the search index: 419,914 messages" over a complete index until the
    // next message happened to arrive. Without a fraction that is not a sidebar row either,
    // so the claim was visible in one place and unfinishable in both.
    let indexed = try await store.indexedCount()
    if try await store.isBackfillComplete() {
      await setState(.ready(indexed: indexed))
    } else {
      await setState(.building(indexed: indexed, fraction: nil))
    }
    // Published BEFORE the backfill, not after: an edit arriving while the history is still
    // being walked has to reach the index too. Re-indexing a row the backfill has not got to
    // yet is harmless — it writes what the row says now, and the backfill writes the same
    // thing again when it arrives.
    await publisher.publish(messageReindexer: Reindexer(service: self))
    pump.run { [weak self] in await self?.run(repository) }
  }

  /// The hook the message watcher calls. A tiny value rather than the service itself, so
  /// what is published is the one operation rather than everything an actor happens to have.
  private struct Reindexer: MessageReindexing {
    let service: MessageSearchIndexService
    func reindex(rowIDs: [Int64]) async { await service.reindex(rowIDs: rowIDs) }
  }

  /// Makes the index agree with what these rows say now.
  ///
  /// Called when the watcher sees a message edited or unsent. Both are the same operation
  /// here: read the row, and either replace its words or remove it. A row that has lost its
  /// text — an unsend — comes back absent from `searchableText`, which is what distinguishes
  /// "say something different now" from "say nothing now".
  func reindex(rowIDs: [Int64]) async {
    guard !rowIDs.isEmpty, let repository = messages else { return }
    // Only while there is an open index to write to. The other states have no store —
    // switched off, unsupported, stopped — and reaching for one would be a caught throw and
    // a log line per edit rather than a silent no-op.
    switch state {
    case .building, .ready: await performReindex(rowIDs, repository)
    case .idle, .disabled, .unsupported: return
    }
  }

  private func performReindex(_ rowIDs: [Int64], _ repository: MessageRepository) async {
    do {
      let rows = try await repository.searchableText(rowIDs: rowIDs)
      let byRowID = Dictionary(uniqueKeysWithValues: rows.map { ($0.rowID, $0.text) })
      let connection = try await store.connection()
      try await connection.write { database in
        for rowID in rowIDs {
          // Always DELETE first. For an edit that clears the old words before the new ones
          // land; for an unsend the delete IS the operation, and there is nothing to insert.
          try database.execute(
            sql: "DELETE FROM message_search WHERE rowid = ?", arguments: [rowID])
          guard let text = byRowID[rowID] else { continue }
          try database.execute(
            sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
            arguments: [rowID, text])
        }
      }
      logger.debug(
        "Re-indexed changed messages", metadata: ["count": .stringConvertible(rowIDs.count)])
    } catch {
      // The cursor is untouched by this path, so a failure costs staleness on those rows
      // until something else re-reads them, not a gap in the index.
      logger.debug(
        "A search index re-read failed",
        metadata: ["error": .string(String(describing: error))])
    }
  }

  func stop() async {
    // Withdrawn FIRST. A handle left published after the store closes takes writes for a
    // database that is no longer open — or one the user has just switched off and expects to
    // be gone.
    await publisher.withdrawMessageReindexer()
    // Waited for BEFORE the close: a backfill batch still writing would otherwise be closed
    // underneath, or keep the writer busy so the close fails.
    await pump.stop()
    try? await store.close()
    await setState(.idle)
  }

  /// Restart on any change this service watches, which is the switch and nothing else.
  ///
  /// A restart is the right response in both directions: on means build, off means delete,
  /// and `start()` already does whichever the switch says.
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      switch state {
      case .idle: .stopped
      case .disabled: .running
      case .unsupported(let reason): .degraded(reason: reason)
      case .building(let indexed, let fraction):
        // The fraction is what makes the sidebar list this as a task rather than Home list
        // it as a problem; `ServiceHealth.degraded` says so. The count is formatted here
        // because this string is read, not parsed: Home shows it after "Running, but".
        .degraded(
          reason: "building the search index: \(indexed.formatted()) messages",
          progress: fraction)
      case .ready: .running
      }
    }
  }

  /// The pump is the index: without it nothing new is indexed and no backfill finishes. Only
  /// asked of the two states that run one; switched off and unsupported have nothing to die.
  var isAlive: Bool {
    get async {
      switch state {
      case .building, .ready: pump.isRunning
      case .idle, .disabled, .unsupported: true
      }
    }
  }

  // MARK: - The pump

  /// One loop for both phases, rather than "backfill, then steady state".
  ///
  /// The shape matters: a rebuild asked for from the settings screen sets
  /// `backfill_complete` back to false, and a run structured as "build once, then poll" has
  /// no way back to the building half. Asking at the top of each pass means the same code
  /// serves the first build, a resumption after a crash, and a rebuild a person requested —
  /// and none of them is a path the other two do not exercise.
  private func run(_ repository: MessageRepository) async {
    var lastToken: Int?
    var isFirstPass = true

    while !Task.isCancelled {
      if !isFirstPass {
        do { try await Task.sleep(for: pollInterval) } catch { return }
        guard !Task.isCancelled else { return }
      }
      isFirstPass = false

      do {
        // Before anything reads the cursor, and on every pass rather than only the first:
        // a restore happens while the server is running as readily as between launches.
        if try await discardIndexIfDatabaseWasReplaced(repository) {
          // The token described the old file. Forgetting it stops the pass after this one
          // from deciding nothing has changed and skipping the walk it now needs.
          lastToken = nil
        }
        if try await store.isBackfillComplete() {
          // Steady state. A tick that finds nothing costs one PRAGMA.
          let token = try await repository.changeToken()
          guard token != lastToken else { continue }
          lastToken = token
          // Not as progress: a handful of arriving messages is not a build. See the
          // parameter's own documentation for what claiming otherwise did.
          let added = try await indexNewMessages(repository, progress: nil)
          try await pruneDeletedMessages(repository, committedToken: token)
          if added > 0 {
            // The count a person reads, kept current without ever leaving `.ready`.
            await setState(.ready(indexed: try await store.indexedCount()))
          }
        } else {
          try await backfill(repository)
          // Forgotten on purpose: a rebuild has to re-read rows this token already covers,
          // so carrying it over would skip the first incremental pass after one.
          lastToken = nil
        }
      } catch is CancellationError {
        return
      } catch {
        // Logged at debug rather than warning: a transient read failure resolves on the
        // next tick, and a minute-by-minute warning for something self-healing is how a
        // support log becomes unreadable.
        logger.debug(
          "A search index pass failed and will be retried",
          metadata: ["error": .string(String(describing: error))])
      }
    }
  }

  /// How often the index is reconciled against the rows that still exist.
  ///
  /// An hour, and gated on a commit as well, so on a Mac where nothing is happening it
  /// never runs at all. See `pruneDeletedMessages`.
  static let pruneInterval: Duration = .seconds(3600)

  /// Row ids compared per pass. Ten thousand is 2 ms on the index side, measured over a
  /// 420,000-row index, and 80 KB of `Int64` on each side of the comparison.
  static let pruneWindow: Int64 = 10_000

  /// When the last reconcile finished, and the commit counter it saw.
  private var lastPrune: ContinuousClock.Instant?
  private var lastPruneToken: Int?

  /// Removes the words of messages that are no longer in `chat.db`.
  ///
  /// **This is residue, not wrong answers.** A deleted message's row id resolves to nothing,
  /// so the join drops it and no search returns it — that part was always right. What was
  /// wrong is that its WORDS stayed: `message.ROWID` is `AUTOINCREMENT`, so the id is never
  /// reused and the entry sat there for the life of the index. Someone who deleted a message
  /// on purpose was left with a file recording which words it contained, and `fts5vocab` can
  /// enumerate a vocabulary. The copy shown at onboarding says turning the feature off
  /// deletes the index; it does not promise that deleting one message leaves the rest of it
  /// untouched, and it should not have to.
  ///
  /// **Nothing reports a deletion, so this has to look.** The forward cursor never revisits a
  /// row, and the watcher does not observe deletions — `ChangeDetectionService` says as much
  /// where it forwards edits and unsends. `date_edited` is unindexed in `chat.db`, and there
  /// is no "deleted" column to query at all.
  ///
  /// So it is a sweep, and the cost is kept down three ways. It runs at most hourly. It runs
  /// only when `chat.db` has been committed to since the last one — a deletion IS a commit,
  /// so an unchanged token means nothing can have gone, which is the same gate
  /// `ChangeDetector` puts on its reconcile pass. And it walks in windows: a rowid range on
  /// the FTS table is 2 ms per ten thousand, measured, against 78 ms to scan a whole
  /// 420,000-row index, so the whole reconcile is well under a second and never holds more
  /// than 80 KB of ids on either side.
  private func pruneDeletedMessages(
    _ repository: MessageRepository, committedToken: Int?
  ) async throws {
    if let lastPrune, ContinuousClock.now - lastPrune < pruneInterval { return }
    // A deletion is a commit like any other, so an unchanged counter means there is nothing
    // to find. A failed read (nil) does not gate: the sweep runs on the interval alone.
    if let committedToken, let lastPruneToken, committedToken == lastPruneToken { return }

    let ceiling = try await store.backfillCursor()
    guard ceiling > 0 else { return }
    let connection = try await store.connection()
    var removed = 0
    var lower: Int64 = 1

    while lower <= ceiling {
      try Task.checkCancellation()
      let upper = min(lower + Self.pruneWindow - 1, ceiling)
      // Frozen before the closure, which is `@Sendable` and may not capture a mutable var.
      let (from, through) = (lower, upper)
      let indexed = try await connection.read { database in
        try Int64.fetchAll(
          database,
          sql: "SELECT rowid FROM message_search WHERE rowid BETWEEN ? AND ?",
          arguments: [from, through])
      }
      if !indexed.isEmpty {
        let alive = try await repository.messageRowIDs(from: lower, through: upper)
        let gone = indexed.filter { !alive.contains($0) }
        if !gone.isEmpty {
          try await connection.write { database in
            for rowID in gone {
              try database.execute(
                sql: "DELETE FROM message_search WHERE rowid = ?", arguments: [rowID])
            }
          }
          removed += gone.count
        }
      }
      lower = upper + 1
    }

    lastPrune = ContinuousClock.now
    lastPruneToken = committedToken

    guard removed > 0 else { return }
    // The count a person reads has to come down with them, or the settings row drifts
    // upward of what the file actually holds.
    let remaining = max(0, try await store.indexedCount() - removed)
    try await store.setIndexedCount(remaining)
    await setState(.ready(indexed: remaining))
    logger.info(
      "Removed deleted messages from the search index",
      metadata: [
        "removed": .stringConvertible(removed),
        "remaining": .stringConvertible(remaining),
      ])
  }

  /// Throws the index away when `chat.db` is not the file it was built from.
  ///
  /// **The index maps `message.ROWID` to words, and a ROWID only means anything inside one
  /// copy of the database.** A restore, a rebuild or a migration reassigns them from 1, so
  /// every row this index holds then names a DIFFERENT message: a search returns messages
  /// that do not contain the term, with a confident total beside them. And it never heals on
  /// its own — the cursor sits above the new maximum, so the walk ends immediately, while
  /// `backfill_complete` is still true in the index's own state file and the reader goes on
  /// trusting it.
  ///
  /// **Asked by IDENTITY, not by magnitude**, and the difference is not academic. The
  /// obvious cheap signal is "the maximum ROWID has fallen below the cursor", and it is
  /// wrong: deleting the NEWEST message produces exactly that state in a database nobody
  /// replaced, and leaves it that way until the next message arrives, because
  /// `AUTOINCREMENT` does not reissue the id. An unsend, or deleting the last message in a
  /// conversation, would then discard a 418,000-row index and rebuild it — silently, and
  /// every time. `deletingTheNewestMessageIsNotAReplacement` is that case, and it fails if
  /// this goes back to comparing maxima.
  ///
  /// So the index pins one message when it starts building (`SearchIndexStore.origin`) and
  /// asks that row what its `guid` is now. `message.ROWID` is `AUTOINCREMENT`, so within one
  /// file an id is never reused, which makes the three answers exact:
  ///
  ///   - the same guid — the same database. Nothing to do, and this is every ordinary pass.
  ///   - a DIFFERENT guid — another message holds that id, which can only happen if the
  ///     file was rebuilt. Replaced.
  ///   - no row — that one message was deleted. Says nothing about the file, so the index
  ///     re-pins to the oldest row still there and carries on.
  ///
  /// It costs an integer-primary-key seek per pass, which is what the magnitude check cost
  /// too. `ChangeDetector` guards the same hazard on the maximum; it can afford to, because
  /// what a false positive costs IT is re-announcing a window of messages rather than
  /// throwing away a quarter of a million rows.
  ///
  /// - Returns: whether the index was discarded.
  private func discardIndexIfDatabaseWasReplaced(
    _ repository: MessageRepository
  ) async throws -> Bool {
    // Nothing indexed yet, so nothing can be wrong yet.
    guard try await store.backfillCursor() > 0 else { return false }
    guard let origin = try await store.origin() else {
      // No pin: an index that finished before one was recorded. Adopt one now rather than
      // rebuilding, because "I do not know" is not evidence of a replacement.
      try await pinOrigin(repository)
      return false
    }

    switch try await repository.messageGUID(rowID: origin.rowID) {
    case origin.guid:
      return false
    case nil:
      // The pinned message was deleted. Re-pin and carry on: one row going is the ordinary
      // case this whole guard must not mistake for a replacement.
      try await pinOrigin(repository)
      return false
    default:
      break
    }

    logger.warning(
      "chat.db is not the database the search index was built from; rebuilding from nothing",
      metadata: ["pinnedRowID": .stringConvertible(origin.rowID)])
    // A new FILE, not `requestRebuild()`. The rows are not stale, they are wrong: a rebuild
    // would rewrite the ones below the new maximum and leave every one above it matching
    // for ever. See `SearchIndexStore.rebuildFromEmpty`.
    switch try await store.rebuildFromEmpty() {
    case .available:
      await setState(.building(indexed: 0, fraction: nil))
    case .unsupported(let reason):
      // It held an index a moment ago, so this is a genuine failure rather than an old
      // SQLite. Reported and left alone: the reader sees a closed store and falls back.
      await setState(.unsupported(reason: reason))
    }
    return true
  }

  /// Records which database this index is being built from. See `SearchIndexStore.origin`.
  ///
  /// The oldest row, because the point is to pick one that will still be there next time:
  /// the newest message is the likeliest of all of them to be deleted or undone.
  private func pinOrigin(_ repository: MessageRepository) async throws {
    guard let identity = try await repository.oldestMessageIdentity() else { return }
    try await store.setOrigin(rowID: identity.rowID, guid: identity.guid)
  }

  /// Walks the whole table once, resumably.
  private func backfill(_ repository: MessageRepository) async throws {
    let started = ContinuousClock.now
    // Pinned BEFORE the walk, not after: a pin recorded at the end would leave a window
    // where a finished index has no idea which database it came from.
    try await pinOrigin(repository)
    // Measured once, here, and not per page: see `BackfillExtent` for both halves of why.
    let extent = BackfillExtent(
      start: try await store.backfillCursor(),
      ceiling: try await repository.maximumMessageRowID() ?? 0)
    let indexed = try await indexNewMessages(repository, progress: extent)
    try Task.checkCancellation()
    try await store.setBackfillComplete(true)
    let total = try await store.indexedCount()
    await setState(.ready(indexed: total))
    logger.info(
      "The message search index is ready",
      metadata: [
        "indexed": .stringConvertible(total),
        "added": .stringConvertible(indexed),
        "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
      ])
  }

  /// Indexes everything above the cursor, a page at a time, and returns how many it wrote.
  ///
  /// The same code serves the backfill and the steady state, because they are the same
  /// operation: the backfill is this starting from zero. One implementation means the
  /// resumption logic is exercised on every tick rather than only after an interruption.
  ///
  /// - Parameter progress: the extent to announce each page against as `.building`, or nil
  ///   to index quietly.
  ///
  ///   Only the backfill passes one. Announcing used to be unconditional, and the consequence
  ///   was not visible until the settings screen started following the service's health: in
  ///   the steady state ONE arriving message flipped the state to `.building` and nothing
  ///   ever set it back, so `health` reported `degraded(reason: "building the search index")`
  ///   for the rest of the process's life over an index that was complete. Indexing four new
  ///   messages a minute is not a build, and saying so made a finished feature look broken.
  @discardableResult
  private func indexNewMessages(
    _ repository: MessageRepository, progress extent: BackfillExtent?
  ) async throws -> Int {
    var cursor = try await store.backfillCursor()
    var written = 0

    while true {
      try Task.checkCancellation()
      let page = try await repository.searchableText(afterRowID: cursor, limit: Self.pageSize)
      // An empty page is the end. It is NOT the same as a page whose rows all resolved to
      // nothing: `searchableText` drops those and still moves the cursor, which is why the
      // loop ends on the highest ROWID it saw rather than on an empty result.
      guard let highest = try await highestRowID(repository, after: cursor, page: page) else {
        break
      }

      if !page.isEmpty {
        let connection = try await store.connection()
        try await connection.write { database in
          for row in page {
            // DELETE then INSERT rather than a bare INSERT: a row re-indexed after an edit
            // would otherwise accumulate both its old and new words. `contentless_delete=1`
            // is what makes the DELETE possible at all.
            try database.execute(
              sql: "DELETE FROM message_search WHERE rowid = ?", arguments: [row.rowID])
            try database.execute(
              sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
              arguments: [row.rowID, row.text])
          }
        }
        written += page.count
      }

      cursor = highest
      // After the page, not after the run: an interruption costs at most one page.
      try await store.setBackfillCursor(cursor)
      if let extent {
        await setState(
          .building(
            indexed: try await store.indexedCount() + written,
            fraction: extent.fraction(at: cursor)))
      }
    }

    if written > 0 {
      try await store.setIndexedCount(try await store.indexedCount() + written)
      logger.debug(
        "Indexed messages for search", metadata: ["count": .stringConvertible(written)])
    }
    return written
  }

  /// The highest ROWID this pass has accounted for, or nil when there is nothing left.
  ///
  /// Needed because `searchableText` DROPS rows with no words in them — an attachment with no
  /// caption, a tapback — so a page can come back empty while rows remain. Advancing on the
  /// page alone would stall the cursor on the first such run of rows for ever.
  private func highestRowID(
    _ repository: MessageRepository, after cursor: Int64,
    page: [MessageRepository.SearchableText]
  ) async throws -> Int64? {
    if let last = page.last { return last.rowID }
    // Nothing came back with text. Either the table ends here, or every row in the window
    // was text-free; asking for the maximum tells the two apart in one indexed lookup.
    guard let maximum = try await repository.maximumMessageRowID(), maximum > cursor else {
      return nil
    }
    return min(cursor + Int64(Self.pageSize), maximum)
  }
}
