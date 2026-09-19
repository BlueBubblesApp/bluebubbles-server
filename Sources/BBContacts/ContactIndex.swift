//  ContactIndex
//  Address -> contact, as an indexed lookup.
//
//  This lookup is on the hot path: it runs once per handle during message serialization, so
//  a 2000-contact address book must not cost a map rebuild plus four suffix scans per
//  message.
//
//  The matching RULE is preserved exactly, because it is what makes "+1 (555) 010-1234" in
//  the address book match "5550101234" from chat.db: strip non-alphanumerics, then try the
//  full string as a suffix, then drop one leading character, then two, then three. First
//  match wins. That last part matters: dropping up to three leading characters is how a
//  country code and a trunk prefix get tolerated, and it is also why the match is fuzzy
//  enough to occasionally pick the wrong contact. We keep the behavior; fixing it would
//  change which name a client displays.
//
//  The cost: because SQLite can range-scan a prefix but not a suffix, the
//  normalized address is stored REVERSED and indexed, so "ends with these digits" becomes a
//  prefix range on an index: four indexed probes instead of four scans over a map that no
//  longer has to be built at all.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import BBPersistence
import Foundation
import GRDB

// MARK: - Model

public enum ContactSource: Int, Sendable, Codable, CaseIterable {
  /// Highest precedence: it is the address book the user actually curates.
  ///
  /// This covers EVERY account configured in Contacts: iCloud, on-device, and CardDAV
  /// accounts including Google. There is deliberately no separate Google case: the current
  /// server has one only because `node-mac-contacts` cannot see CardDAV contacts, and that
  /// is a bug in how it enumerates rather than something the address book withholds.
  case macOS = 0
  /// Contacts created through POST /api/v1/contact. Lowest precedence.
  ///
  /// Raw value 2, with 1 left unused where the Google source was: the numbers are stored
  /// in the database, so renumbering would silently reinterpret existing rows.
  case local = 2

  /// What a person calls it: the Account column's fallback, and the label the bulk control
  /// groups under. Here rather than in the app because the SQL that groups by it needs the
  /// same string, and two spellings would put a group in the menu that no row displays.
  public var label: String {
    switch self {
    case .macOS: "Address Book"
    case .local: "Local"
    }
  }
}

/// Which account in Contacts a record synced from.
///
/// `ContactSource` answers "did this come from the address book or from our own API", which is
/// a different question and is frozen into the wire format as `db`/`api`. This answers "which
/// account in the address book", which is what a user actually wants to know when two entries
/// for the same person disagree.
///
/// The name is kept verbatim alongside the inferred kind ON PURPOSE. Contacts.framework exposes
/// a container's type (`local`, `cardDAV`, `exchange`) but not the service behind it: iCloud
/// and Google are both CardDAV, so the kind is a heuristic over the container name. Keeping the
/// name means a wrong guess is visible rather than authoritative.
public struct ContactAccount: Sendable, Codable, Equatable {

  public enum Kind: String, Sendable, Codable, CaseIterable {
    case onThisMac
    case iCloud
    case google
    case exchange
    case other
    /// Not from the address book at all: created through POST /api/v1/contact.
    case server
  }

  public var kind: Kind
  /// The container's name as Contacts reports it, when there is one.
  public var name: String?

  public init(kind: Kind, name: String? = nil) {
    self.kind = kind
    self.name = name
  }

  /// What to show a user.
  public var label: String {
    switch kind {
    case .onThisMac: "On this Mac"
    case .iCloud: "iCloud"
    case .google: "Google"
    case .exchange: "Exchange"
    // The container's own name is more use than the word "other".
    case .other: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Other account"
    case .server: "Local"
    }
  }

  /// Infers the account from a container's type and name.
  ///
  /// `containerType` is the raw `CNContainerType` value, passed as a string so this stays
  /// testable without Contacts.framework and without a platform gate.
  public static func infer(containerType: String, name: String?) -> ContactAccount {
    let trimmed = (name ?? "").trimmingCharacters(in: .whitespaces)
    let lowered = trimmed.lowercased()

    switch containerType {
    case "local":
      return ContactAccount(kind: .onThisMac, name: trimmed.isEmpty ? nil : trimmed)
    case "exchange":
      return ContactAccount(kind: .exchange, name: trimmed.isEmpty ? nil : trimmed)
    case "cardDAV":
      // Both iCloud and Google arrive as CardDAV, so the name is the only signal.
      if lowered.contains("google") || lowered.contains("gmail") {
        return ContactAccount(kind: .google, name: trimmed)
      }
      // "Card" is what iCloud's container has been called since the AddressBook days;
      // an empty name is the other way it shows up.
      if lowered.contains("icloud") || lowered == "card" || trimmed.isEmpty {
        return ContactAccount(kind: .iCloud, name: trimmed.isEmpty ? nil : trimmed)
      }
      return ContactAccount(kind: .other, name: trimmed)
    default:
      return ContactAccount(kind: .other, name: trimmed.isEmpty ? nil : trimmed)
    }
  }
}

public enum AddressKind: Int, Sendable, Codable {
  case phone = 0
  case email = 1
}

public struct ContactRecord: Sendable, Identifiable, Codable {
  public let id: String
  public let source: ContactSource
  public var firstName: String?
  public var lastName: String?
  public var displayName: String?
  public var nickname: String?
  public var birthday: String?
  /// The identifier in the source system. Identity keys off THIS rather than off the name,
  /// so two people with the same name do not collide.
  public var externalID: String?
  /// The id as clients see it: the stored key with the address-book prefix removed.
  ///
  /// A computed projection rather than a second stored column, because there is only one
  /// identifier: the prefix is a namespacing detail of sharing one table between two
  /// sources, and nothing outside storage should know about it.
  public var wireID: String {
    id.hasPrefix(ContactIndex.addressBookPrefix)
      ? String(id.dropFirst(ContactIndex.addressBookPrefix.count)) : id
  }
  public var phoneNumbers: [String]
  public var emailAddresses: [String]
  /// Which address-book account this came from, when it came from one.
  public var account: ContactAccount?

  public init(
    id: String,
    source: ContactSource,
    firstName: String? = nil,
    lastName: String? = nil,
    displayName: String? = nil,
    nickname: String? = nil,
    birthday: String? = nil,
    externalID: String? = nil,
    phoneNumbers: [String] = [],
    emailAddresses: [String] = [],
    account: ContactAccount? = nil
  ) {
    self.id = id
    self.source = source
    self.firstName = firstName
    self.lastName = lastName
    self.displayName = displayName
    self.nickname = nickname
    self.birthday = birthday
    self.externalID = externalID
    self.phoneNumbers = phoneNumbers
    self.emailAddresses = emailAddresses
    self.account = account
  }
}

// MARK: - Normalization

public enum AddressNormalizer {

  /// Strips everything that is not `[a-zA-Z0-9_]`.
  ///
  /// Matches the alphaNumericRegex in findContact exactly, underscore included. Note it
  /// does NOT lowercase: the reference does not either, so `Bob@example.com` and `bob@example.com`
  /// are different keys today. We lowercase emails at INDEX time instead (below), which
  /// makes matching strictly better without changing what a correct match returns.
  public static func strip(_ address: String) -> String {
    String(
      address.unicodeScalars.filter { scalar in
        (scalar >= "a" && scalar <= "z")
          || (scalar >= "A" && scalar <= "Z")
          || (scalar >= "0" && scalar <= "9")
          || scalar == "_"
      }.map(Character.init))
  }

  public static func classify(_ address: String) -> AddressKind {
    address.contains("@") ? .email : .phone
  }

  /// The stored key. Emails lowercase; phone numbers keep their digits as-is.
  public static func normalize(_ address: String, kind: AddressKind) -> String {
    let stripped = strip(address)
    return kind == .email ? stripped.lowercased() : stripped
  }

  public static func reversed(_ normalized: String) -> String {
    String(normalized.reversed())
  }
}

// MARK: - The index

public actor ContactIndex {

  private let database: AppDatabase
  /// Small, bounded, and keyed by the query address. Serialization asks for the same
  /// handles repeatedly within one response, so this absorbs the burst without holding a
  /// full contact list in memory.
  private var lookupCache: BoundedCache<String, ContactRecord?>

  public init(database: AppDatabase, cacheCapacity: Int = 512) {
    self.database = database
    self.lookupCache = BoundedCache(capacity: cacheCapacity, ttl: .seconds(300))
  }

  // MARK: Lookup

  /// The hot path. Four indexed range probes, shortest-drop last, first match wins.
  public func findContact(address: String) async throws -> ContactRecord? {
    // Double optional on purpose: the outer says "cached", the inner says "cached as no
    // match". Caching a miss is most of the value here: an unknown number is looked up
    // once per message otherwise.
    if let cached = lookupCache[address] { return cached }

    let kind = AddressNormalizer.classify(address)
    let normalized = AddressNormalizer.normalize(address, kind: kind)
    guard !normalized.isEmpty else { return nil }

    let result = try await resolve(normalized: normalized, kind: kind)
    lookupCache.insert(result, for: address)
    return result
  }

  private func resolve(normalized: String, kind: AddressKind) async throws -> ContactRecord? {
    // An email is matched WHOLE: by equality, not by a zero-drop suffix probe.
    //
    // The distinction is not pedantic. Normalization strips non-alphanumerics, so
    // `a@example.com` becomes "aexamplecom" and `bba@example.com` becomes
    // "bbaexamplecom". The second ends with the first, so a suffix match (even with
    // drop == 0) resolves one person's address to another person's contact. Only an
    // equality probe is correct here.
    if kind == .email {
      return try await matchExactReversed(AddressNormalizer.reversed(normalized))
    }

    for drop in [0, 1, 2, 3] {
      guard normalized.count > drop else { break }
      let candidate = String(normalized.dropFirst(drop))
      // Below this length a suffix match is noise, not a match. The current code has
      // no such floor and will happily match a 3-digit tail against every contact.
      guard candidate.count >= 4 else { break }

      if let contact = try await matchSuffix(candidate) { return contact }
    }
    return nil
  }

  /// `normalized LIKE '%candidate'`, expressed as an indexed prefix range on `reversed`.
  ///
  /// The upper bound is the prefix with its last scalar incremented, which is the standard
  /// way to turn a prefix match into a half-open range a B-tree can seek. Falls back to an
  /// equality probe when that increment would overflow.
  private func matchSuffix(_ candidate: String) async throws -> ContactRecord? {
    let prefix = AddressNormalizer.reversed(candidate)
    guard let upperBound = Self.rangeUpperBound(of: prefix) else {
      return try await matchExactReversed(prefix)
    }

    return try await database.read { db in
      // Ordered by source so macOS Contacts wins over Google over local when several
      // contacts carry the same number, deterministically.
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT c.id, c.source, c.first_name, c.last_name, c.display_name,
                 c.nickname, c.birthday, c.external_id,
                 c.account_kind, c.account_name
          FROM contact_address a
          JOIN contact c ON c.id = a.contact_id
          WHERE a.reversed >= ? AND a.reversed < ?
            AND \(Self.enabledPredicate)
          ORDER BY c.source ASC, LENGTH(a.normalized) ASC, c.id ASC
          LIMIT 1
          """, arguments: [prefix, upperBound])
      guard let row else { return nil }
      return try Self.hydrate(row: row, db: db)
    }
  }

  private func matchExactReversed(_ prefix: String) async throws -> ContactRecord? {
    try await database.read { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT c.id, c.source, c.first_name, c.last_name, c.display_name,
                 c.nickname, c.birthday, c.external_id,
                 c.account_kind, c.account_name
          FROM contact_address a
          JOIN contact c ON c.id = a.contact_id
          WHERE a.reversed = ?
            AND \(Self.enabledPredicate)
          ORDER BY c.source ASC, c.id ASC
          LIMIT 1
          """, arguments: [prefix])
      guard let row else { return nil }
      return try Self.hydrate(row: row, db: db)
    }
  }

  /// Batch form for serializing a page of messages.
  ///
  /// NOT one query: it is a loop over the deduplicated addresses, one lookup each. The
  /// comment used to claim otherwise. What the batching actually buys is the deduplication
  /// — a page of a hundred messages in one conversation is one lookup, not a hundred — and
  /// a single call site instead of one per serializer. Worth making a real batch if a page
  /// ever spans enough distinct addresses for it to matter; it does not today.
  public func findContacts(addresses: [String]) async throws -> [String: ContactRecord] {
    var result: [String: ContactRecord] = [:]
    for address in Set(addresses) {
      if let contact = try await findContact(address: address) {
        result[address] = contact
      }
    }
    return result
  }

  // MARK: Ingest

  /// Replaces every address row for the given contacts, then inserts fresh ones.
  ///
  /// Called with a bounded batch from a streaming enumeration: never with the whole
  /// address book. The caller drives `CNContactStore.enumerateContacts` and hands batches
  /// here, so peak memory is the batch, not the address book.
  public func upsert(_ contacts: [ContactRecord], now: Date = Date()) async throws {
    guard !contacts.isEmpty else { return }

    try await database.write { db in
      try ContactIndex.write(contacts, to: db, now: now)
    }

    // Any cached miss could now be a hit.
    lookupCache.removeAll()
  }

  /// Blocking form, for the Contacts enumeration callback which cannot await.
  ///
  /// `nonisolated` so the ingestor can call it from inside that callback without hopping
  /// onto this actor: hopping would require a suspension it cannot perform.
  public nonisolated func upsertSynchronously(_ contacts: [ContactRecord], now: Date = Date())
    throws
  {
    guard !contacts.isEmpty else { return }
    try database.writeSynchronously { db in
      try ContactIndex.write(contacts, to: db, now: now)
    }
  }

  /// Invalidates the lookup cache. Called after a synchronous batch run completes, since
  /// `upsertSynchronously` cannot touch actor state.
  public func invalidateCache() {
    lookupCache.removeAll()
  }

  private static func write(_ contacts: [ContactRecord], to db: Database, now: Date) throws {
    for contact in contacts {
      try db.execute(
        sql: """
          INSERT INTO contact
              (id, source, first_name, last_name, display_name, nickname,
               birthday, external_id, account_kind, account_name, search_haystack,
               updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
              source = excluded.source,
              first_name = excluded.first_name,
              last_name = excluded.last_name,
              display_name = excluded.display_name,
              nickname = excluded.nickname,
              birthday = excluded.birthday,
              external_id = excluded.external_id,
              account_kind = excluded.account_kind,
              account_name = excluded.account_name,
              search_haystack = excluded.search_haystack,
              updated_at = excluded.updated_at
          """,
        arguments: [
          contact.id, contact.source.rawValue, contact.firstName, contact.lastName,
          contact.displayName, contact.nickname, contact.birthday,
          contact.externalID, contact.account?.kind.rawValue, contact.account?.name,
          // Written on every upsert, so a contact re-indexed after a rename is findable
          // by the new name and not by the old one.
          ContactSearchText.haystack(for: contact),
          now,
        ])

      // Delete-then-insert rather than diffing: a contact's address list is small,
      // and diffing would have to handle a number moving between contacts.
      try db.execute(
        sql: "DELETE FROM contact_address WHERE contact_id = ?",
        arguments: [contact.id]
      )

      let addresses =
        contact.phoneNumbers.map { ($0, AddressKind.phone) }
        + contact.emailAddresses.map { ($0, AddressKind.email) }

      for (raw, kind) in addresses {
        let normalized = AddressNormalizer.normalize(raw, kind: kind)
        guard !normalized.isEmpty else { continue }
        // `raw` alongside the key, because the key is lossy BY DESIGN: it strips
        // everything that is not alphanumeric so that "+1 (555) 010-1234" and
        // "5550101234" collide. Storing only the key meant every read, including
        // GET /api/v1/contact, handed back `personnameexample.com` for an address the
        // user entered as `person.name@example.com`.
        try db.execute(
          sql: """
            INSERT OR REPLACE INTO contact_address
                (normalized, reversed, kind, contact_id, raw)
            VALUES (?, ?, ?, ?, ?)
            """,
          arguments: [
            normalized, AddressNormalizer.reversed(normalized),
            kind.rawValue, contact.id, raw,
          ])
      }
    }
  }

  /// Removes contacts by identifier. Address rows cascade.
  public func remove(ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    try await database.write { db in
      let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
      try db.execute(
        sql: "DELETE FROM contact WHERE id IN (\(placeholders))",
        arguments: StatementArguments(ids)
      )
    }
    lookupCache.removeAll()
  }

  /// Drops everything from one source without touching the others: how a full re-index of
  /// macOS Contacts runs without discarding Google or locally-created contacts.
  public func removeAll(source: ContactSource) async throws {
    try await database.write { db in
      try db.execute(
        sql: "DELETE FROM contact WHERE source = ?", arguments: [source.rawValue]
      )
    }
    lookupCache.removeAll()
  }

  /// How many contacts this server would serve.
  ///
  /// Excludes the ones switched off, because this backs `GET /contact/count` and a count that
  /// disagrees with the list it counts is worse than no count.
  public func count() async throws -> Int {
    try await database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM contact c WHERE \(Self.enabledPredicate)") ?? 0
    }
  }

  /// Accepts the id as STORED or as SERIALISED, which are not the same for an address-book
  /// record.
  ///
  /// One table holds both sources, so an address-book row is keyed `macos:<identifier>` to
  /// keep it from colliding with a client-created one. The reference has two stores and sends
  /// the bare identifier, so that is what goes on the wire, and a client that reads an `id`
  /// from `GET /contact` and hands it back to `PUT`, `DELETE` or `/contact/:id/avatar` sends
  /// the bare form. Looking up only the stored form would 404 every address-book contact the
  /// client had just been given.
  public func contact(id: String) async throws -> ContactRecord? {
    try await database.read { db in
      // Exact first: a client-created id is stored as it is serialised, and an id that
      // already carries the prefix must not be prefixed twice.
      let candidates =
        id.hasPrefix(Self.addressBookPrefix)
        ? [id] : [id, Self.addressBookPrefix + id]
      for candidate in candidates {
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT id, source, first_name, last_name, display_name, nickname,
                   birthday, external_id, account_kind, account_name
            FROM contact WHERE id = ?
            """, arguments: [candidate])
        if let row { return try Self.hydrate(row: row, db: db) }
      }
      return nil
    }
  }

  /// Namespaces an address-book record's primary key. Storage only; never on the wire.
  public static let addressBookPrefix = "macos:"

  /// Every contact, paged. Used by GET /api/v1/contact, which must still return the full
  /// list; but it streams a page at a time rather than materializing everything.
  /// One contact by its identifier in the source system.
  ///
  /// Distinct from `contact(id:)`, which takes our own row id. External identifiers are
  /// what a client that synced from Google or the address book already holds, and looking
  /// one up is how it avoids creating a duplicate.
  public func contact(externalID: String) async throws -> ContactRecord? {
    try await database.read { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT id, source, first_name, last_name, display_name, nickname,
                 birthday, external_id, account_kind, account_name
          FROM contact WHERE external_id = ? LIMIT 1
          """, arguments: [externalID])
      guard let row else { return nil }
      return try Self.hydrate(row: row, db: db)
    }
  }

  public func page(limit: Int, offset: Int) async throws -> [ContactRecord] {
    try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT c.id, c.source, c.first_name, c.last_name, c.display_name, c.nickname,
                 c.birthday, c.external_id, c.account_kind, c.account_name
          FROM contact c WHERE \(Self.enabledPredicate) ORDER BY c.id LIMIT ? OFFSET ?
          """, arguments: [limit, offset])
      return try Self.hydrate(rows: rows, db: db)
    }
  }

  /// A contact the user has switched off.
  ///
  /// **Disabling reaches NAME RESOLUTION, not just the contact endpoints.** That is the
  /// stronger reading of "do not serve this contact" and it is the one chosen: a message from
  /// a disabled contact shows the raw address in every client and in notifications, because
  /// this predicate is on the lookups that turn a handle into a name as well as on the lists.
  ///
  /// Written as `NOT EXISTS` rather than `NOT IN`: `NOT IN` against a subquery that can yield
  /// NULL answers NULL for every row, which would serve nobody at all.
  static let enabledPredicate =
    "NOT EXISTS (SELECT 1 FROM contact_disabled d WHERE d.contact_id = c.id)"

  /// Switches contacts off, or back on.
  ///
  /// Recorded by id, which survives a re-index: `reindexAll` deletes and re-inserts every
  /// address-book row, and this table is deliberately not joined to it by a cascading key.
  /// A contact deleted from the address book therefore leaves its row here, and gets its
  /// setting back if it ever returns — which is the behaviour somebody who unlinked an
  /// account and relinked it would expect.
  public func setEnabled(_ enabled: Bool, ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    try await database.write { db in
      let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
      if enabled {
        try db.execute(
          sql: "DELETE FROM contact_disabled WHERE contact_id IN (\(placeholders))",
          arguments: StatementArguments(ids))
      } else {
        let now = Date()
        for id in ids {
          try db.execute(
            sql: """
              INSERT INTO contact_disabled (contact_id, disabled_at) VALUES (?, ?)
              ON CONFLICT(contact_id) DO NOTHING
              """, arguments: [id, now])
        }
      }
    }
    // The resolution cache holds records keyed by address, so a contact switched off while
    // its name is cached would go on being served until the entry expired. Five minutes of
    // a setting appearing not to work is worse than dropping a cache nobody is timing.
    lookupCache.removeAll()
  }

  /// Switches every contact shown under one Account label off, or back on.
  ///
  /// Matched on the label the table DISPLAYS — the account name, falling back to the account
  /// kind and then to the source — so "disable everything from Google" means what the person
  /// reading that column thinks it means. `ContactOrder.account` sorts by the same expression,
  /// so the group a bulk action covers is exactly the block the sort puts together.
  ///
  /// It applies to the contacts that exist NOW. A contact synced later into an account that
  /// was bulk-disabled arrives enabled, because every contact is enabled by default and a
  /// stored per-account rule would be a second source of truth about the same question.
  @discardableResult
  public func setEnabled(_ enabled: Bool, accountLabel: String) async throws -> Int {
    let changed = try await database.write { db -> Int in
      let expression = ContactOrder.account.expression
      let ids = try String.fetchAll(
        db, sql: "SELECT c.id FROM contact c WHERE \(expression) = ?",
        arguments: [accountLabel])
      guard !ids.isEmpty else { return 0 }
      let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
      if enabled {
        try db.execute(
          sql: "DELETE FROM contact_disabled WHERE contact_id IN (\(placeholders))",
          arguments: StatementArguments(ids))
      } else {
        let now = Date()
        for id in ids {
          try db.execute(
            sql: """
              INSERT INTO contact_disabled (contact_id, disabled_at) VALUES (?, ?)
              ON CONFLICT(contact_id) DO NOTHING
              """, arguments: [id, now])
        }
      }
      return ids.count
    }
    lookupCache.removeAll()
    return changed
  }

  /// Every Account label in the index, with how many contacts carry it, for the bulk control.
  public func accountLabels() async throws -> [(label: String, count: Int)] {
    try await database.read { db in
      let expression = ContactOrder.account.expression
      return try Row.fetchAll(
        db,
        sql: """
          SELECT \(expression) AS label, COUNT(*) AS total
          FROM contact c GROUP BY label ORDER BY label ASC
          """
      ).map { (label: $0["label"] as String, count: $0["total"] as Int) }
    }
  }

  /// How a paged read is ordered.
  ///
  /// The table's four sortable columns, expressed once here rather than as SQL at the call
  /// site: a page is a window onto an ordered set, so the order has to be the DATABASE's or
  /// the window shows the wrong rows. Sorting a page in the app would reorder fifty of four
  /// thousand contacts behind a control that looks exactly like one sorting all of them.
  public enum ContactOrder: String, Sendable, CaseIterable {
    case name
    case phone
    case email
    case account

    /// The ORDER BY expression, over `contact c`.
    ///
    /// Phone and email order by the contact's FIRST address of that kind. A contact has any
    /// number of them and "sort by phone" has no other meaning; `MIN` makes it deterministic
    /// rather than dependent on insertion order. A contact with none sorts last under `ASC`,
    /// because `NULL` is ordered first by SQLite and an empty column at the top is a column
    /// that looks unsorted.
    fileprivate var expression: String {
      switch self {
      case .name:
        // What the table shows in that column, so clicking it sorts what is on screen.
        "COALESCE(NULLIF(TRIM(c.display_name), ''), "
          + "NULLIF(TRIM(COALESCE(c.first_name, '') || ' ' || COALESCE(c.last_name, '')), ''), "
          + "c.id)"
      case .phone:
        "(SELECT MIN(COALESCE(a.raw, a.normalized)) FROM contact_address a "
          + "WHERE a.contact_id = c.id AND a.kind = \(AddressKind.phone.rawValue))"
      case .email:
        "(SELECT MIN(COALESCE(a.raw, a.normalized)) FROM contact_address a "
          + "WHERE a.contact_id = c.id AND a.kind = \(AddressKind.email.rawValue))"
      case .account:
        // The label the column actually shows, so the order matches it and the bulk control
        // groups by it: the account name, then the account kind, then the SOURCE — spelled the
        // way the table spells it.
        //
        // `CAST(c.source AS TEXT)` was the fallback, which is the stored enum's raw value: a
        // contact with no account grouped under "2", while the row beside it read "Local".
        // Two names for one group, and the bulk menu offered the one nobody could see.
        "COALESCE(NULLIF(TRIM(c.account_name), ''), NULLIF(TRIM(c.account_kind), ''), "
          + "CASE c.source WHEN \(ContactSource.macOS.rawValue) THEN "
          + "'\(ContactSource.macOS.label)' ELSE '\(ContactSource.local.label)' END)"
      }
    }
  }

  /// One page of contacts, with how many match in total.
  ///
  /// The two together, from ONE read, deliberately. Asked separately they are two reads of a
  /// table that an ingest can rewrite between them, and the page then says "showing 51-100 of
  /// 40" — which is what a person sees the moment a Google account is unlinked while they are
  /// looking at the list.
  public struct ContactPage: Sendable {
    public let contacts: [ContactRecord]
    /// Matching the query, before the page was taken.
    public let total: Int
    /// Which of THESE contacts are switched off.
    ///
    /// Beside the records rather than on them: `ContactRecord` is what the API serializes, and
    /// a disabled contact never reaches the API, so the flag would be a wire field that is
    /// false in every response it could ever appear in.
    public let disabledIDs: Set<String>

    public init(contacts: [ContactRecord], total: Int, disabledIDs: Set<String> = []) {
      self.contacts = contacts
      self.total = total
      self.disabledIDs = disabledIDs
    }
  }

  /// A page of contacts matching `query`, ordered and counted in SQL.
  ///
  /// An empty query matches everything, which is the direction that cannot hide a person's
  /// contacts from them.
  ///
  /// Matching prefers the stored `search_haystack` and falls back to the name and address
  /// columns when it is NULL. That fallback is what keeps a contact indexed before the
  /// haystack existed findable until its next re-index, rather than making everyone's
  /// contacts vanish from search on upgrade. It is not identical — the fallback cannot match
  /// the FORMATTED spelling of a number — which is the honest cost of not backfilling a
  /// column whose input some old rows no longer have.
  /// - Parameter includeDisabled: whether contacts the user has switched off are returned.
  ///   Defaults to FALSE, so every caller that forgets to think about it gets the serving
  ///   behaviour rather than the administering one. The app's own table passes true, because
  ///   a switch you cannot see is a switch you cannot undo.
  public func search(
    query: String,
    order: ContactOrder = .name,
    ascending: Bool = true,
    limit: Int,
    offset: Int,
    includeDisabled: Bool = false
  ) async throws -> ContactPage {
    let pattern = ContactSearchText.pattern(for: query)
    let direction = ascending ? "ASC" : "DESC"

    // `\` as the escape character, matching what `pattern(for:)` escapes with: without it a
    // query containing % or _ is a wildcard rather than the characters somebody typed.
    let enabled = includeDisabled ? "1" : Self.enabledPredicate
    let matching =
      pattern == nil
      ? "1"
      : """
      CASE WHEN c.search_haystack IS NOT NULL
           THEN c.search_haystack LIKE :pattern ESCAPE '\\'
           ELSE (
             LOWER(COALESCE(c.display_name, '')) LIKE :pattern ESCAPE '\\'
             OR LOWER(COALESCE(c.first_name, '')) LIKE :pattern ESCAPE '\\'
             OR LOWER(COALESCE(c.last_name, '')) LIKE :pattern ESCAPE '\\'
             OR LOWER(COALESCE(c.nickname, '')) LIKE :pattern ESCAPE '\\'
             OR EXISTS (
               SELECT 1 FROM contact_address a WHERE a.contact_id = c.id
               AND (a.normalized LIKE :pattern ESCAPE '\\'
                    OR LOWER(COALESCE(a.raw, '')) LIKE :pattern ESCAPE '\\')
             )
           )
      END
      """
    // Both halves, and the enabled half is not optional: a caller that asks for a page
    // without saying it wants the switched-off ones must not be shown them.
    let predicate = "(\(enabled)) AND (\(matching))"

    return try await database.read { db in
      var arguments: [String: any DatabaseValueConvertible] = [:]
      if let pattern { arguments["pattern"] = pattern }

      let total =
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM contact c WHERE \(predicate)",
          arguments: StatementArguments(arguments)
        ) ?? 0

      var pageArguments = arguments
      pageArguments["limit"] = limit
      pageArguments["offset"] = offset
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT c.id, c.source, c.first_name, c.last_name, c.display_name, c.nickname,
                 c.birthday, c.external_id, c.account_kind, c.account_name
          FROM contact c
          WHERE \(predicate)
          -- Nullness FIRST, so a contact with no address of this kind sorts last in both
          -- directions. SQLite orders NULL before everything, so without this an ascending
          -- sort by Phone opened with every contact that has no phone number, which reads as
          -- a sort that did not happen. `c.id` breaks ties so a page is stable: equal keys in
          -- an arbitrary order mean a row can appear on two pages and on neither.
          ORDER BY (\(order.expression)) IS NULL ASC, \(order.expression) \(direction), c.id ASC
          LIMIT :limit OFFSET :offset
          """,
        arguments: StatementArguments(pageArguments))

      let contacts = try Self.hydrate(rows: rows, db: db)
      var disabled: Set<String> = []
      if includeDisabled, !contacts.isEmpty {
        let placeholders = contacts.map { _ in "?" }.joined(separator: ", ")
        disabled = Set(
          try String.fetchAll(
            db,
            sql: "SELECT contact_id FROM contact_disabled WHERE contact_id IN (\(placeholders))",
            arguments: StatementArguments(contacts.map(\.id))))
      }
      return ContactPage(contacts: contacts, total: total, disabledIDs: disabled)
    }
  }

  // MARK: Internals

  /// The address as it was entered, falling back to the lookup key.
  ///
  /// Rows written before `raw` existed have none, and there is nothing to recover it from:
  /// the original was never stored. They read as they did before until the next re-index,
  /// which is strictly better than dropping them.
  private static func address(_ row: Row) -> String? {
    (row["raw"] as String?) ?? (row["normalized"] as String?)
  }

  /// A PAGE of contacts, with their addresses read in one query.
  ///
  /// `hydrate(row:db:)` asks for one contact's addresses, which is right for a single lookup
  /// and wrong for a list: a page of a hundred cost a hundred and one queries, and the number
  /// grew with the page rather than staying put. One `IN` clause, grouped in memory.
  ///
  /// Order is the caller's: the rows come back in whatever the query's `ORDER BY` decided, and
  /// a page is a window onto that ordering, so this must not re-sort them.
  private static func hydrate(rows: [Row], db: Database) throws -> [ContactRecord] {
    guard !rows.isEmpty else { return [] }
    let ids = rows.map { $0["id"] as String }
    let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
    let addressRows = try Row.fetchAll(
      db,
      sql: """
        SELECT contact_id, normalized, raw, kind FROM contact_address
        WHERE contact_id IN (\(placeholders))
        """,
      arguments: StatementArguments(ids)
    )
    var addressesByContact: [String: [Row]] = [:]
    for row in addressRows {
      addressesByContact[row["contact_id"] as String, default: []].append(row)
    }
    return rows.map { row in
      hydrate(row: row, addresses: addressesByContact[row["id"] as String] ?? [])
    }
  }

  private static func hydrate(row: Row, db: Database) throws -> ContactRecord {
    let id: String = row["id"]
    let addresses = try Row.fetchAll(
      db,
      sql: "SELECT normalized, raw, kind FROM contact_address WHERE contact_id = ?",
      arguments: [id]
    )
    return hydrate(row: row, addresses: addresses)
  }

  /// Builds one record from a contact row and the addresses already read for it.
  ///
  /// The shared half of the two above, so a single lookup and a page cannot drift into
  /// describing the same contact differently.
  private static func hydrate(row: Row, addresses: [Row]) -> ContactRecord {
    let id: String = row["id"]

    let account: ContactAccount? = (row["account_kind"] as String?)
      .flatMap(ContactAccount.Kind.init(rawValue:))
      .map { ContactAccount(kind: $0, name: row["account_name"]) }

    return ContactRecord(
      id: id,
      source: ContactSource(rawValue: row["source"] ?? 0) ?? .local,
      firstName: row["first_name"],
      lastName: row["last_name"],
      displayName: row["display_name"],
      nickname: row["nickname"],
      birthday: row["birthday"],
      externalID: row["external_id"],
      phoneNumbers:
        addresses
        .filter { ($0["kind"] as Int?) == AddressKind.phone.rawValue }
        .compactMap(Self.address),
      emailAddresses:
        addresses
        .filter { ($0["kind"] as Int?) == AddressKind.email.rawValue }
        .compactMap(Self.address),
      account: account
    )
  }

  /// The exclusive upper bound for a prefix range: the prefix with its final scalar
  /// incremented. Returns nil when the last scalar cannot be incremented, in which case
  /// the caller falls back to an equality probe.
  static func rangeUpperBound(of prefix: String) -> String? {
    guard let last = prefix.unicodeScalars.last else { return nil }
    guard last.value < 0x10FFFF, let next = Unicode.Scalar(last.value + 1) else { return nil }
    var scalars = String.UnicodeScalarView(prefix.unicodeScalars.dropLast())
    scalars.append(next)
    return String(scalars)
  }
}
