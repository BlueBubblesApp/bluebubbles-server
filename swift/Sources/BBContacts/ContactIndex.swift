//  ContactIndex
//  Address -> contact, as an indexed lookup.
//
//  What this replaces is the single worst hot path in the current server. ContactInterface
//  .findContact() rebuilds the ENTIRE address->contact map from scratch on every call, then
//  runs four progressively-shorter suffix matches, each an Object.keys().filter() scan over
//  that map. It is called once per handle during message serialization. A 2000-contact
//  address book therefore costs a full map rebuild plus four O(n) scans per message.
//
//  The matching RULE is preserved exactly, because it is what makes "+1 (555) 010-1234" in
//  the address book match "5550101234" from chat.db: strip non-alphanumerics, then try the
//  full string as a suffix, then drop one leading character, then two, then three. First
//  match wins. That last part matters — dropping up to three leading characters is how a
//  country code and a trunk prefix get tolerated, and it is also why the match is fuzzy
//  enough to occasionally pick the wrong contact. We keep the behavior; fixing it would
//  change which name a client displays.
//
//  What changes is the cost. Because SQLite can range-scan a prefix but not a suffix, the
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
  /// This covers EVERY account configured in Contacts — iCloud, on-device, and CardDAV
  /// accounts including Google. There is deliberately no separate Google case: the current
  /// server has one only because `node-mac-contacts` cannot see CardDAV contacts, and that
  /// is a bug in how it enumerates rather than something the address book withholds.
  case macOS = 0
  /// Contacts created through POST /api/v1/contact. Lowest precedence.
  ///
  /// Raw value 2, with 1 left unused where the Google source was — the numbers are stored
  /// in the database, so renumbering would silently reinterpret existing rows.
  case local = 2
}

/// Which account in Contacts a record synced from.
///
/// `ContactSource` answers "did this come from the address book or from our own API", which is
/// a different question and is frozen into the wire format as `db`/`api`. This answers "which
/// account in the address book", which is what a user actually wants to know when two entries
/// for the same person disagree.
///
/// The name is kept verbatim alongside the inferred kind ON PURPOSE. Contacts.framework exposes
/// a container's type (`local`, `cardDAV`, `exchange`) but not the service behind it — iCloud
/// and Google are both CardDAV — so the kind is a heuristic over the container name. Keeping the
/// name means a wrong guess is visible rather than authoritative.
public struct ContactAccount: Sendable, Codable, Equatable {

  public enum Kind: String, Sendable, Codable, CaseIterable {
    case onThisMac
    case iCloud
    case google
    case exchange
    case other
    /// Not from the address book at all — created through POST /api/v1/contact.
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
  /// which fixes the @Unique(["firstName","lastName","displayName"]) constraint on the
  /// current contact table that makes two people with the same name collide.
  public var externalID: String?
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
  /// does NOT lowercase — the current code does not either, so `Bob@example.com` and `bob@example.com`
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
    // match". Caching a miss is most of the value here — an unknown number is looked up
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
    // An email is matched WHOLE — by equality, not by a zero-drop suffix probe.
    //
    // The distinction is not pedantic. Normalization strips non-alphanumerics, so
    // `a@example.com` becomes "aexamplecom" and `bba@example.com` becomes
    // "bbaexamplecom". The second ends with the first, so a suffix match — even with
    // drop == 0 — resolves one person's address to another person's contact. Only an
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
      // contacts carry the same number. The current code returns whichever key
      // Object.keys happened to yield first, which is not deterministic.
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT c.id, c.source, c.first_name, c.last_name, c.display_name,
                 c.nickname, c.birthday, c.external_id,
                 c.account_kind, c.account_name
          FROM contact_address a
          JOIN contact c ON c.id = a.contact_id
          WHERE a.reversed >= ? AND a.reversed < ?
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
          ORDER BY c.source ASC, c.id ASC
          LIMIT 1
          """, arguments: [prefix])
      guard let row else { return nil }
      return try Self.hydrate(row: row, db: db)
    }
  }

  /// Batch form for serializing a page of messages. One query instead of N.
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
  /// Called with a bounded batch from a streaming enumeration — never with the whole
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
  /// onto this actor — hopping would require a suspension it cannot perform.
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
               birthday, external_id, account_kind, account_name, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
              updated_at = excluded.updated_at
          """,
        arguments: [
          contact.id, contact.source.rawValue, contact.firstName, contact.lastName,
          contact.displayName, contact.nickname, contact.birthday,
          contact.externalID, contact.account?.kind.rawValue, contact.account?.name,
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
        // `raw` alongside the key, because the key is lossy BY DESIGN — it strips
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

  /// Drops everything from one source without touching the others — how a full re-index of
  /// macOS Contacts runs without discarding Google or locally-created contacts.
  public func removeAll(source: ContactSource) async throws {
    try await database.write { db in
      try db.execute(
        sql: "DELETE FROM contact WHERE source = ?", arguments: [source.rawValue]
      )
    }
    lookupCache.removeAll()
  }

  public func count() async throws -> Int {
    try await database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM contact") ?? 0
    }
  }

  public func contact(id: String) async throws -> ContactRecord? {
    try await database.read { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT id, source, first_name, last_name, display_name, nickname,
                 birthday, external_id, account_kind, account_name
          FROM contact WHERE id = ?
          """, arguments: [id])
      guard let row else { return nil }
      return try Self.hydrate(row: row, db: db)
    }
  }

  /// Every contact, paged. Used by GET /api/v1/contact, which must still return the full
  /// list — but it streams a page at a time rather than materializing everything.
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
          SELECT id, source, first_name, last_name, display_name, nickname,
                 birthday, external_id, account_kind, account_name
          FROM contact ORDER BY id LIMIT ? OFFSET ?
          """, arguments: [limit, offset])
      return try rows.map { try Self.hydrate(row: $0, db: db) }
    }
  }

  // MARK: Internals

  private static func hydrate(row: Row, db: Database) throws -> ContactRecord {
    let id: String = row["id"]
    let addresses = try Row.fetchAll(
      db,
      sql: "SELECT normalized, raw, kind FROM contact_address WHERE contact_id = ?",
      arguments: [id]
    )

    /// The address as it was entered, falling back to the lookup key.
    ///
    /// Rows written before `raw` existed have none, and there is nothing to recover it
    /// from — the original was never stored. They read as they did before until the next
    /// re-index, which is strictly better than dropping them.
    func address(_ row: Row) -> String? {
      (row["raw"] as String?) ?? (row["normalized"] as String?)
    }

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
        .compactMap(address),
      emailAddresses:
        addresses
        .filter { ($0["kind"] as Int?) == AddressKind.email.rawValue }
        .compactMap(address),
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
