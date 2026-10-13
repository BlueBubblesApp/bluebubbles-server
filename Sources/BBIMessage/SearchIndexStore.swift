//  SearchIndexStore
//  The file the message search index lives in, and the only thing that creates or destroys it.
//
//  macOS 26 stopped populating `message.text`: the words are in `attributedBody`, where a SQL
//  `LIKE` cannot reach them, so searching finds almost nothing sent since the update. There is
//  no index to borrow — `chat.db` carries no FTS table at all, and the text Messages donates
//  goes to a per-app CoreSpotlight domain that only Messages' own process can query. An index
//  of our own is the only route that does not require injecting a helper. See `docs/SEARCH.md`
//  for the measurements behind every choice here.
//
//  Three properties this type exists to guarantee:
//
//  **It cannot stop the server.** It is a separate file opened on demand, never a
//  `SchemaContributor`. A table declared that way is created inside `AppDatabase.open`, and a
//  migration that throws there takes the whole process down — which an optional, rebuildable
//  cache must never be able to do. Here the worst case is `unsupported`, and the feature says
//  so.
//
//  **Turning it off leaves nothing behind.** `destroy()` removes the file and its sidecars.
//  That is checkable in a way `DELETE FROM` is not: deleted rows free pages that still hold
//  the old tokens until something vacuums them.
//
//  **What it stores is a word list, not the conversations.** `content=''` keeps no copy of the
//  text, and `detail='none'` keeps no token positions either, so the index answers "row 4182
//  contains this word" and cannot be read back as sentences. It is not nothing — `fts5vocab`
//  can still enumerate the vocabulary — which is why the feature is opt-in and why the file is
//  written `0600`.

import BBCore
import Foundation
import GRDB
import Logging

/// The search index file: its schema, its lifecycle, and whether this Mac can have one.
public actor SearchIndexStore {

  /// Bumped whenever a stored row would be read differently than it was written.
  ///
  /// A tokenizer change is the case to watch: `remove_diacritics 2` decides that `café` and
  /// `cafe` are one word, so an index built under one setting and queried under another
  /// disagrees with itself silently. A mismatch is not repaired, it is rebuilt — the whole
  /// index costs seconds, and a partial migration of an inverted index is not worth writing.
  static let schemaVersion = 2

  /// The FTS5 options, in one place because they are a package rather than four choices.
  ///
  /// - `content=''` — contentless: the inverted index only, never a second copy of the text.
  ///   We already hold the text in `chat.db` and only ever need the row id back.
  /// - `contentless_delete=1` — lets a row be deleted and re-inserted WITHOUT handing FTS5
  ///   the original text. Without it a contentless table refuses `DELETE` outright, and an
  ///   edited message could never have its stale tokens removed. **This is the option that
  ///   decides whether this Mac can have an index at all**; see `Availability`.
  /// - `detail='none'` — no token positions. Halves the file, cuts the build's peak memory to
  ///   a fifth, and is what keeps the index from being reconstructable back into text. It
  ///   costs phrase queries, which the reference does not really do either: its Spotlight
  ///   path tokenizes the term and matches any token.
  /// - `unicode61 remove_diacritics 2` — the standard tokenizer, folding accents, so a search
  ///   for `cafe` finds `café`.
  static let tableDefinition = """
    CREATE VIRTUAL TABLE message_search USING fts5(
      text,
      content='',
      contentless_delete=1,
      detail='none',
      tokenize='unicode61 remove_diacritics 2'
    )
    """

  /// Whether this Mac can hold an index, and why not when it cannot.
  public enum Availability: Sendable, Equatable {
    case available
    /// SQLite here is too old for `contentless_delete`, which arrived in 3.43. The floor is
    /// macOS 14, and the SQLite that ships with it has NOT been verified against this — so
    /// the check is made by trying, at runtime, rather than by comparing version numbers
    /// against a table nobody has confirmed.
    case unsupported(reason: String)

    public var isAvailable: Bool { self == .available }
  }

  private let url: URL
  private let logger: Logger
  private var queue: DatabaseQueue?

  public init(
    url: URL = ApplicationSupport.searchIndex,
    logger: Logger = Logger(label: "bluebubbles.search.index")
  ) {
    self.url = url
    self.logger = logger
  }

  /// Where the index is, for a caller that needs to report or remove it.
  public nonisolated var fileURL: URL { url }

  /// Whether the file exists. Says nothing about whether it is current or complete.
  public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

  // MARK: - Opening

  /// Opens the index, creating it if there is none, rebuilding it if its schema has moved.
  ///
  /// Returns the availability rather than throwing for the unsupported case, because "this
  /// Mac cannot do this" is an answer a caller acts on, not an error it recovers from. A
  /// genuine I/O failure still throws.
  @discardableResult
  public func open() async throws -> Availability {
    if queue != nil { return .available }

    try ApplicationSupport.hardenDirectory(at: url.deletingLastPathComponent())

    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    let opened = try DatabaseQueue(path: url.path, configuration: configuration)
    try Self.restrictPermissions(of: url)

    let stored = try await Self.storedVersion(in: opened)
    if let stored, stored != Self.schemaVersion {
      // Rebuilt rather than migrated: see `schemaVersion`.
      logger.info(
        "The search index was built by a different version and will be rebuilt",
        metadata: [
          "stored": .stringConvertible(stored),
          "expected": .stringConvertible(Self.schemaVersion),
        ])
      try opened.close()
      try destroyFiles()
      return try await open()
    }

    if stored == nil {
      switch try await Self.createSchema(in: opened) {
      case .available:
        break
      case .unsupported(let reason):
        // Nothing half-built is left on disk: an empty file that cannot hold an index is
        // indistinguishable, later, from one that simply has not been filled yet.
        try? opened.close()
        try? destroyFiles()
        logger.warning(
          "This Mac cannot hold a message search index",
          metadata: ["reason": .string(reason)])
        lastAvailability = .unsupported(reason: reason)
        return .unsupported(reason: reason)
      }
    }

    queue = opened
    lastAvailability = .available
    return .available
  }

  /// Closes the index without removing it.
  public func close() async throws {
    guard let queue else { return }
    self.queue = nil
    try queue.close()
  }

  /// Closes the index and removes it from disk, sidecars included.
  ///
  /// What the settings switch calls when it is turned off. The file is the whole of the
  /// feature's residue, so this is what makes "turning it off deletes it" true rather than
  /// aspirational.
  public func destroy() async throws {
    try await close()
    try destroyFiles()
  }

  private func destroyFiles() throws {
    let manager = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
      let path = url.path + suffix
      guard manager.fileExists(atPath: path) else { continue }
      try manager.removeItem(atPath: path)
    }
  }

  // MARK: - State

  /// How far a backfill has reached: every message with a lower or equal `ROWID` is indexed.
  ///
  /// A high-water mark rather than a count, so an interrupted backfill resumes from where it
  /// stopped instead of starting again or, worse, carrying on from wherever it happens to
  /// think it was.
  public func backfillCursor() async throws -> Int64 {
    try await connection().read { db in
      try Int64.fetchOne(db, sql: "SELECT backfill_cursor FROM search_state WHERE id = 1") ?? 0
    }
  }

  public func setBackfillCursor(_ rowID: Int64) async throws {
    try await connection().write { db in
      try db.execute(
        sql: "UPDATE search_state SET backfill_cursor = ? WHERE id = 1", arguments: [rowID])
    }
  }

  /// Whether the backfill has walked the whole table at least once.
  public func isBackfillComplete() async throws -> Bool {
    try await connection().read { db in
      try Bool.fetchOne(db, sql: "SELECT backfill_complete FROM search_state WHERE id = 1")
        ?? false
    }
  }

  public func setBackfillComplete(_ complete: Bool) async throws {
    try await connection().write { db in
      try db.execute(
        sql: """
          UPDATE search_state SET backfill_complete = ?, completed_at = ? WHERE id = 1
          """,
        arguments: [complete, complete ? Date() : nil])
    }
  }

  /// Throws the index away and asks for it to be built again.
  ///
  /// A FLAG, not an action: it resets the three pieces of state the backfill reads and lets
  /// the service that owns the writing do the writing. The alternative — the app reaching
  /// for the service and restarting it — needs a capability the app deliberately does not
  /// have, and would restart the service's dependents with it.
  ///
  /// The rows are left in place rather than deleted. The backfill walks from zero and
  /// re-writes each one (`DELETE` then `INSERT`, as it always does), so clearing them here
  /// would only mean a window where search finds less than it could. `isBackfillComplete`
  /// going false is already what makes the reader fall back to `LIKE`.
  public func requestRebuild() async throws {
    try await connection().write { db in
      try db.execute(
        sql: """
          UPDATE search_state
          SET backfill_cursor = 0, backfill_complete = 0, indexed_count = 0, completed_at = NULL
          WHERE id = 1
          """)
    }
  }

  /// Which `chat.db` this index was built from, as one message it contains.
  ///
  /// **A named row, not a count or a maximum, because only identity answers the question.**
  /// `message.ROWID` is `AUTOINCREMENT`, so within one database an id is never reused: if
  /// the row that had this id now carries a DIFFERENT `guid`, the file itself has been
  /// replaced and every row id the index holds names the wrong message.
  ///
  /// The obvious cheaper signal — the maximum ROWID having gone below the cursor — is not
  /// the same question, and mistaking one for the other is expensive in the wrong
  /// direction. Deleting the NEWEST message produces exactly that state in a database
  /// nobody replaced, and it stays that way until the next message arrives, because
  /// `AUTOINCREMENT` does not reissue the id. So an unsend, or deleting the last message in
  /// a conversation, would have thrown the whole index away and rebuilt it, silently.
  /// `deletingTheNewestMessageIsNotAReplacement` is that case, and it fails if this ever
  /// goes back to comparing maxima.
  ///
  /// Nil before the first backfill has pinned one.
  public func origin() async throws -> (rowID: Int64, guid: String)? {
    try await connection().read { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT origin_row_id, origin_guid FROM search_state WHERE id = 1"),
        let rowID = row["origin_row_id"] as Int64?,
        let guid = row["origin_guid"] as String?
      else { return nil }
      return (rowID, guid)
    }
  }

  public func setOrigin(rowID: Int64, guid: String) async throws {
    try await connection().write { db in
      try db.execute(
        sql: "UPDATE search_state SET origin_row_id = ?, origin_guid = ? WHERE id = 1",
        arguments: [rowID, guid])
    }
  }

  /// Throws the whole file away and opens an empty one in its place.
  ///
  /// Distinct from `requestRebuild()`, and the difference is whether the ROWS ARE STILL
  /// TRUE. A rebuild asked for on the settings screen leaves them: they map the same row ids
  /// to the same words, the walk rewrites each one, and clearing them would only widen the
  /// window where search finds less than it could. When `chat.db` has been REPLACED — a
  /// restore, a rebuild, a migration — every stored row id names a different message, so
  /// the rows are not stale, they are wrong, and leaving them would have the walk rewrite
  /// the ones below the new maximum while the ones above it went on matching for ever.
  ///
  /// A new file rather than `DELETE FROM`, for the reason `destroy()` exists: deleted rows
  /// free pages that still hold the old tokens until something vacuums them.
  @discardableResult
  public func rebuildFromEmpty() async throws -> Availability {
    try await destroy()
    return try await open()
  }

  /// What the last `open()` decided, for a screen that has to explain itself.
  ///
  /// Remembered rather than recomputed: the answer costs a `CREATE VIRTUAL TABLE` to find
  /// out, and asking again on every render would be a schema probe per frame.
  public private(set) var lastAvailability: Availability = .available

  /// How many messages the index holds. A `COUNT` over a contentless table, so it reads the
  /// state row rather than the index itself.
  public func indexedCount() async throws -> Int {
    try await connection().read { db in
      try Int.fetchOne(db, sql: "SELECT indexed_count FROM search_state WHERE id = 1") ?? 0
    }
  }

  public func setIndexedCount(_ count: Int) async throws {
    try await connection().write { db in
      try db.execute(
        sql: "UPDATE search_state SET indexed_count = ? WHERE id = 1", arguments: [count])
    }
  }

  // MARK: - Reading

  /// The `message.ROWID`s whose text matches, newest first, capped.
  ///
  /// Returns nil when the index cannot answer — not open, not yet backfilled, the term is one
  /// a token index cannot express, or the read itself failed. Nil means "use `LIKE`", and an
  /// EMPTY array means "the index looked and there is nothing", which are different answers
  /// and must not be collapsed here. What the CALLER does with an empty array is its own
  /// decision; see `MessageRepository.resolvingSearch`, which also falls back on one.
  ///
  /// **Does not throw, and reports its own failures.** A read failure here is not the
  /// caller's to handle: the answer is always "use `LIKE`", which is what the server did
  /// before the index existed. The rule this obeys is the one about `try?` — a swallowed
  /// failure has to be reported on some path, and a `try?` at the call site reported it on
  /// none, so a corrupt index degraded every search silently and for ever. This type owns a
  /// logger; the repository does not. So the catch is here, beside the logger, and the call
  /// site has no `try?` to forget.
  ///
  /// **The cap is a real limit on the answer, not a paging detail.** The row ids come back
  /// as a set that the caller turns into `m.ROWID IN (…)` and then orders by DATE, so the
  /// whole set has to be present for the ordering to be right — taking the first hundred
  /// here and sorting those would return an arbitrary hundred, not the newest hundred.
  /// Ordering the cap by `rowid DESC` is what makes it defensible: `message.ROWID` is
  /// assigned in arrival order, so the newest matches are the ones kept, which is the
  /// direction a message search is read in.
  ///
  /// What the cap costs is now only the INDEX-ONLY half of the answer: the caller ORs these
  /// row ids with the client's own `m.text LIKE ?`, which has no cap, so a term past the
  /// limit still reports every message whose column contains it plus the newest ten
  /// thousand the index adds. Before that was a union the cap was the whole answer, and
  /// `%the%` reported a `total` of 10,000 against 90,628 in the column.
  public func matchingRowIDs(
    likeTerm term: String, limit: Int = defaultMatchLimit, newestFirst: Bool = true
  ) async -> [Int64]? {
    guard let queue else { return nil }
    switch MessageSearchTerm.from(likeTerm: term) {
    case .notExpressible(let reason):
      // The REASON and never the term. A search term is whatever a person typed, which is
      // message content by any other name; `LogRedactionPolicyTests` is the backstop but
      // the rule is the point. `trace`, because this is one line per request on a server
      // whose clients search as the user types.
      logger.trace(
        "A search term is going the LIKE path",
        metadata: ["reason": .string(reason.rawValue)])
      return nil
    case .match(let expression):
      do {
        guard try await isBackfillComplete() else { return nil }
        let order = newestFirst ? "DESC" : "ASC"
        return try await queue.read { db in
          try Int64.fetchAll(
            db,
            sql: """
              SELECT rowid FROM message_search
              WHERE message_search MATCH ? ORDER BY rowid \(order) LIMIT ?
              """,
            arguments: [expression, max(0, limit)])
        }
      } catch {
        // Warning rather than debug: unlike a pass that will retry in a minute, this one
        // does not heal. Every search from here on takes the slow path and finds nothing
        // on macOS 26, and the only thing that fixes it is a person pressing Rebuild.
        logger.warning(
          "The search index could not be read; searches will fall back to LIKE",
          metadata: ["error": .string(String(describing: error))])
        return nil
      }
    }
  }

  /// How many matches a single search may resolve.
  ///
  /// Ten thousand: far past any page a client asks for, small enough that the
  /// `m.ROWID IN (…)` it becomes stays a reasonable statement, and reached only by a term so
  /// common that the hundred rows a client will actually read are the newest ones either way.
  public static let defaultMatchLimit = 10_000

  /// The open connection, for the indexer and the reader.
  ///
  /// Throws rather than opening implicitly: a caller that has not opened the store has not
  /// checked whether this Mac can have one, and silently opening here would turn that
  /// omission into a crash somewhere less obvious.
  public func connection() throws -> DatabaseQueue {
    guard let queue else { throw SearchIndexError.notOpen }
    return queue
  }

  // MARK: - Schema

  private static func storedVersion(in queue: DatabaseQueue) async throws -> Int? {
    try await queue.read { db in
      guard try db.tableExists("search_state") else { return nil }
      return try Int.fetchOne(db, sql: "SELECT schema_version FROM search_state WHERE id = 1")
    }
  }

  /// Creates both tables, or reports that this SQLite cannot.
  ///
  /// The unsupported case is detected by ATTEMPTING the create, not by reading
  /// `sqlite_version()` and comparing it against a table of which release gained which
  /// option. The version-number route needs a fact nobody here has verified — what SQLite
  /// macOS 14 ships — and would be wrong in the dangerous direction if the mapping were off.
  private static func createSchema(in queue: DatabaseQueue) async throws -> Availability {
    do {
      try await queue.write { db in
        try db.execute(sql: tableDefinition)
        try db.execute(
          sql: """
            CREATE TABLE search_state (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              schema_version INTEGER NOT NULL,
              backfill_cursor INTEGER NOT NULL DEFAULT 0,
              backfill_complete BOOLEAN NOT NULL DEFAULT 0,
              indexed_count INTEGER NOT NULL DEFAULT 0,
              created_at DATETIME NOT NULL,
              completed_at DATETIME,
              origin_row_id INTEGER,
              origin_guid TEXT
            )
            """)
        try db.execute(
          sql: """
            INSERT INTO search_state (id, schema_version, created_at) VALUES (1, ?, ?)
            """,
          arguments: [schemaVersion, Date()])
      }
      return .available
    } catch let error as DatabaseError {
      // The option this turns on is the one old builds refuse. Anything else is a real
      // failure and is rethrown: a disk that cannot be written to is not a missing feature.
      let message = error.message ?? ""
      guard
        message.contains("contentless_delete") || message.contains("unrecognized")
          || message.contains("unknown")
      else { throw error }
      return .unsupported(
        reason:
          "SQLite on this Mac does not support contentless_delete, which the index needs to "
          + "keep up with edited and deleted messages. It arrived in SQLite 3.43."
      )
    }
  }

  /// `0600`. The index is derived from message text, and the directory it sits in is not
  /// protected by TCC the way `chat.db` is, so file mode is the only thing between it and
  /// any process running as this user.
  private static func restrictPermissions(of url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

public enum SearchIndexError: BBError, Equatable, CustomStringConvertible {
  /// A read or write was attempted before `open()`.
  case notOpen

  public var code: String { "search.index_not_open" }
  public var domain: String { "Search" }
  public var title: String { "Search is not ready" }
  public var description: String { body }

  public var body: String {
    switch self {
    case .notOpen: "The search index is not open."
    }
  }
}
