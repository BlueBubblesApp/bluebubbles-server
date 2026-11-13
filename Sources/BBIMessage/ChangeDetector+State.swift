//  ChangeDetector+State
//  The ledgers the detector carries between ticks: `ArrivalMark`, `HeldArrivals`,
//  `ChatReadLedger` and `CommitLedger`.
//
//  Its own file so each ledger's rule is read as a value, apart from the tick that drives
//  them (`ChangeDetector.swift`). Nothing here reads the database; each takes the rows a tick
//  fetched and answers what the next tick owes.

import BBCore
import Foundation

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

  /// New messages that have been examined and could not be announced yet: waiting for their
  /// `chat_message_join` row, or for a read of them to succeed.
  ///
  /// Apart from `ArrivalMark`, and that is what keeps the mark simple: the mark moves over a
  /// held row like any other, so nothing above it waits, and this set is what brings it back.
  /// A row leaves by being released, so it cannot be announced twice.
  ///
  /// Keyed by ROWID with the time it was first held. Bounded in number by
  /// `maximumAnnouncedPerTick`, because `classify` counts these with each tick's arrivals and
  /// demotes the lot above that, and in time by `maximumHold`.
  struct HeldArrivals {
    private struct Entry {
      let since: Date
      /// The `error` column moved while the row waited, which its `new-message` cannot say.
      var errorMoved = false
    }

    private var entries: [Int64: Entry] = [:]

    var count: Int { entries.count }
    var rowIDs: [Int64] { entries.keys.sorted() }

    func contains(_ rowID: Int64) -> Bool { entries[rowID] != nil }

    /// Holds a row if it is not already held, and returns how long it has been waiting.
    @discardableResult
    mutating func hold(_ rowID: Int64, at now: Date) -> TimeInterval {
      let entry = entries[rowID] ?? Entry(since: now)
      entries[rowID] = entry
      return now.timeIntervalSince(entry.since)
    }

    /// Records a failed send on a held row. Ignores a row that is not held.
    mutating func noteError(_ rowID: Int64) { entries[rowID]?.errorMoved = true }

    /// Whether a failed send has been recorded on this row. False for a row that is not held.
    func errorMoved(_ rowID: Int64) -> Bool { entries[rowID]?.errorMoved == true }

    /// Lets a row go, returning how long it waited, or nil if it was never held.
    @discardableResult
    mutating func release(_ rowID: Int64, at now: Date) -> TimeInterval? {
      entries.removeValue(forKey: rowID).map { now.timeIntervalSince($0.since) }
    }

    mutating func reset() { entries = [:] }
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

    /// The wide pass is due on what the last tick already read, with no commit since.
    ///
    /// A fast tick reads past a commit without reading what it changed on an OLDER message:
    /// its window is the last half hour by send date, so a read receipt or an edit on
    /// yesterday's message is invisible to it. Only the wide pass sees that, and it is owed
    /// from the moment the commit was ticked. Asked of the backup pass, which otherwise ticks
    /// only on a new commit, so without this the receipts wait for whatever writes to chat.db
    /// next: half an hour on a quiet Mac, and then all of them in one burst.
    func isReconcileOwed(now: Date, interval: Duration) -> Bool {
      isReconcileDue(now: now, token: lastToken, interval: interval)
    }

    mutating func markReconciled(at now: Date, token: Int?) {
      lastReconcile = now
      reconcileToken = token
    }
  }
}
