//  ContactInterface
//  Contacts, from the address book and from clients.
//
//  Contacts are the one part of the read path that is not chat.db: they come from the macOS
//  address book, from Google, and from clients that POST their own. `ContactIndex` holds all
//  three with a precedence order; this layer is what the routes and the app talk to.

import BBContacts
import BBCore
import BBSerialization
import Foundation
import Logging

public struct ContactInterface: Sendable {

  private let index: ContactIndex
  private let ingestor: ContactsIngestor?
  private let logger: Logger

  public init(
    index: ContactIndex,
    ingestor: ContactsIngestor? = nil,
    logger: Logger = Logger(label: "bluebubbles.interface.contact")
  ) {
    self.index = index
    self.ingestor = ingestor
    self.logger = logger
  }

  // MARK: - Reading

  /// The wire shape, for the HTTP routes.
  public func list(limit: Int = 1000, offset: Int = 0) async throws -> [JSONValue] {
    try await index.page(limit: limit, offset: offset).map { Self.serialize($0) }
  }

  /// The same contacts as VALUES, for callers in this process. See
  /// `ServerInterface.webhookList()` for why both exist — `ContactRecord` is already
  /// `Identifiable`, which is the thing the contacts table needed and had to fake.
  public func records(limit: Int = 1000, offset: Int = 0) async throws -> [ContactRecord] {
    try await index.page(limit: limit, offset: offset)
  }

  public func count() async throws -> Int {
    try await index.count()
  }

  /// Contacts for specific addresses.
  ///
  /// Batched through `findContacts` rather than looped: this backs the client's initial
  /// sync, which asks about every participant in every chat at once, and one query per
  /// address there is the difference between a fast start and a visibly slow one.
  ///
  /// Addresses with no match are OMITTED rather than returned as null entries — the
  /// current server does the same, and a client reads absence as "no contact".
  public func find(addresses: [String]) async throws -> [JSONValue] {
    let matches = try await index.findContacts(addresses: addresses)
    // Deduplicated by contact id: two addresses belonging to one person would otherwise
    // return that person twice.
    var seen = Set<String>()
    var results: [JSONValue] = []
    for address in addresses {
      guard let record = matches[address], !seen.contains(record.id) else { continue }
      seen.insert(record.id)
      results.append(Self.serialize(record))
    }
    return results
  }

  public func contact(id: String) async throws -> JSONValue? {
    try await index.contact(id: id).map { Self.serialize($0) }
  }

  /// Display names for addresses, for UI that shows who a conversation is with.
  ///
  /// Keyed by the address as it was ASKED FOR, not as the contact stores it — the caller
  /// has the raw address in hand and needs to look the answer back up by it.
  ///
  /// An address with no contact is OMITTED, and that is the whole fallback story: a server
  /// that was never granted contact access has no address-book rows to match, so every
  /// lookup misses, the map comes back empty, and a caller that falls back to the raw
  /// address is already doing the right thing. There is no separate permission check to
  /// make here, and adding one would only be a second way to get the same answer wrong.
  public func displayNames(for addresses: [String]) async throws -> [String: String] {
    try await index.findContacts(addresses: addresses)
      .compactMapValues { Self.displayName(for: $0) }
      .filter { !$0.value.isEmpty }
  }

  // MARK: - Writing

  /// Creates a client-supplied contact.
  ///
  /// Identity keys off `externalID` when the client provides one. That is the fix for the
  /// current server's unique constraint on (firstName, lastName, displayName), which makes
  /// two different people with the same name collide into one row.
  public func create(_ body: JSONValue) async throws -> JSONValue {
    let record = try Self.parse(body, existingID: nil)
    try await index.upsert([record])
    return Self.serialize(record)
  }

  public func update(id: String, body: JSONValue) async throws -> JSONValue {
    guard try await index.contact(id: id) != nil else {
      throw InterfaceError.notFound("no contact with id \(id)")
    }
    let record = try Self.parse(body, existingID: id)
    try await index.upsert([record])
    return Self.serialize(record)
  }

  public func delete(id: String) async throws {
    guard try await index.contact(id: id) != nil else {
      throw InterfaceError.notFound("no contact with id \(id)")
    }
    try await index.remove(ids: [id])
  }

  /// Re-reads the address book.
  ///
  /// Only `.macOS` contacts are replaced; `.local` ones are the client's own and are not
  /// the address book's to remove.
  public func refresh() async throws -> JSONValue {
    guard let ingestor else {
      throw InterfaceError.unavailable("contact access has not been granted to this server")
    }
    let result = try await ingestor.reindexAll()
    return .object([
      "indexed": .int(result.indexed),
      "skipped": .int(result.skipped),
      "durationMs": .int(Int(result.duration.components.seconds * 1000)),
    ])
  }

  /// The contact's avatar bytes.
  ///
  /// Read from `CNContactStore` per contact rather than during the bulk ingest, which is why
  /// the ingest never requests image data at all — bulk-loading every avatar is the memory
  /// pathology this avoids. Every contact resolves this way, including the ones that reach the
  /// address book from Google: an account synced into Contacts is not a different kind of
  /// contact, it is a contact.
  public func avatar(address: String) async throws -> Data {
    guard let ingestor else {
      throw InterfaceError.unavailable("contact access has not been granted to this server")
    }
    guard let record = try await index.findContact(address: address) else {
      throw InterfaceError.notFound("no contact matches \(address)")
    }
    guard let identifier = record.externalID,
      let data = try await ingestor.imageData(identifier: identifier, thumbnail: true)
    else { throw InterfaceError.notFound("that contact has no avatar") }
    return data
  }

  // MARK: - Wire format

  /// The wire shape of `ContactInterface.mapContacts`, which is eleven keys with two
  /// conditional ones.
  ///
  /// Measured against a live Electron server, where this diverged five ways at once — and
  /// the parity harness had been reporting only "552 rows against 587", because it stops at
  /// a length mismatch and never reached the elements. A count difference between two
  /// machines' address books looks like an environment difference, so it was nearly signed
  /// off as one.
  ///
  /// The conditional keys are a JavaScript artifact worth naming, because reproducing it
  /// deliberately looks like a bug: `mapContacts` assigns `nickname: contact?.nickname` and
  /// `birthday: contact?.birthday`, and `JSON.stringify` DROPS a key whose value is
  /// `undefined`. So a contact with no nickname has no `nickname` key at all, while
  /// `externalId` — which reads a real database column and is therefore `null` rather than
  /// undefined — keeps its key. Emitting `"nickname": null` unconditionally is an added key
  /// to a strict parser.
  public static func serialize(_ record: ContactRecord, avatar: String? = nil) -> JSONValue {
    var object = JSONObjectBuilder()

    // `{ address, id }`, not a bare string. The `id` is the source's own identifier for
    // that number and is null for our local records; it was missing entirely.
    object.set(
      "phoneNumbers",
      .array(
        record.phoneNumbers.map {
          .object(["address": .string($0), "id": .null])
        }))
    object.set(
      "emails",
      .array(
        record.emailAddresses.map {
          .object(["address": .string($0), "id": .null])
        }))
    object.setOrNull("firstName", record.firstName.map(JSONValue.string))
    object.setOrNull("lastName", record.lastName.map(JSONValue.string))
    // DERIVED when the record has none, which the reference does and this did not — so a
    // contact stored as first/last with no display name came back with
    // `"displayName": null` where it has always come back "Aaron Bierlein". Clients render
    // this field directly, so the visible symptom is a contact list of blanks.
    object.setOrNull("displayName", Self.displayName(for: record).map(JSONValue.string))
    // Absent, not null, when unset — see above.
    if let nickname = record.nickname { object.set("nickname", .string(nickname)) }
    if let birthday = record.birthday { object.set("birthday", .string(birthday)) }
    // ALWAYS present, and an empty string rather than null when there is no image: the
    // reference defaults it with `isNotEmpty(avatar) ? base64(avatar) : ""`. It was being
    // omitted, so a client rendering an avatar found no key where it has always found one.
    object.set("avatar", .string(avatar ?? ""))
    object.set("sourceType", .string(record.source.wireName))
    object.set("id", .string(record.id))
    object.setOrNull("externalId", record.externalID.map(JSONValue.string))
    return object.build()
  }

  /// The reference's fallback chain, in its order: an explicit display name, then the name
  /// parts, then the nickname.
  ///
  /// Transcribed rather than improved. `mapContacts` writes the first-name-only case and the
  /// both-names case as two separate unguarded `if`s, so both run and the second wins — the
  /// same result as an else-if here, but worth knowing it is not a fallthrough bug being
  /// copied. Nickname is checked last and only if nothing above produced anything.
  static func displayName(for record: ContactRecord) -> String? {
    if let existing = record.displayName, !existing.isEmpty { return existing }

    switch (record.firstName?.isEmpty == false, record.lastName?.isEmpty == false) {
    case (true, true): return "\(record.firstName!) \(record.lastName!)"
    case (true, false): return record.firstName
    default: break
    }
    if let nickname = record.nickname, !nickname.isEmpty { return nickname }
    return nil
  }

  /// Reads a client-supplied contact.
  ///
  /// Accepts both the bare-string and the `{ address: ... }` spelling for phone numbers and
  /// emails, because clients send both — the response shape uses objects, and some clients
  /// echo that back on create.
  static func parse(_ body: JSONValue, existingID: String?) throws -> ContactRecord {
    func addresses(_ key: String) -> [String] {
      (body[key]?.arrayValue ?? []).compactMap { entry in
        entry.stringValue ?? entry["address"]?.stringValue
      }
    }

    let phones = addresses("phoneNumbers")
    let emails = addresses("emails") + addresses("emailAddresses")

    let firstName = body["firstName"]?.stringValue
    let lastName = body["lastName"]?.stringValue
    let displayName = body["displayName"]?.stringValue

    guard firstName != nil || lastName != nil || displayName != nil else {
      throw InterfaceError.invalidRequest(
        "a contact needs at least one of firstName, lastName or displayName")
    }
    guard !phones.isEmpty || !emails.isEmpty else {
      throw InterfaceError.invalidRequest(
        "a contact needs at least one phone number or email address")
    }

    return ContactRecord(
      id: existingID ?? UUID().uuidString,
      source: .local,
      firstName: firstName,
      lastName: lastName,
      displayName: displayName,
      nickname: body["nickname"]?.stringValue,
      birthday: body["birthday"]?.stringValue,
      externalID: body["externalId"]?.stringValue ?? body["externalID"]?.stringValue,
      phoneNumbers: phones,
      emailAddresses: emails,
      // Not from the address book: it arrived through this endpoint.
      account: ContactAccount(kind: .server)
    )
  }
}

extension ContactSource {
  /// The `sourceType` string clients read. Frozen — "api" rather than "local" is what the
  /// current server emits for a client-created contact.
  var wireName: String {
    switch self {
    case .macOS: "api"
    case .local: "db"
    }
  }
}
