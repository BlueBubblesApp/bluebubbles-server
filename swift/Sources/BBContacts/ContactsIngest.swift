//  ContactsIngest
//  Streaming ingest from CNContactStore into the index.
//
//  The behavior being replaced: ContactsLib.getAllContacts() fetches EVERY contact with
//  EVERY extra property — including full-resolution contactImage — purely as a cache-priming
//  side effect, discards the result, then fetches again with the properties actually wanted.
//  On a large address book that is the single biggest allocation the server makes, and it
//  happens for a cache that findContact() then ignores by rebuilding its map anyway.
//
//  Here: enumerateContacts streams one contact at a time, we request only the keys needed to
//  index, image data is never fetched in the bulk pass, and batches are flushed to SQLite so
//  peak memory is the batch rather than the address book.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import BBDiagnostics
import Foundation

#if canImport(Contacts)
  import Contacts
#endif

public enum ContactsAuthorization: Sendable, Equatable {
  case authorized
  case denied
  case restricted
  case notDetermined
  /// Contacts.framework is unavailable. Not an error — the server runs fine without it,
  /// clients just see phone numbers instead of names.
  case unavailable
}

public enum ContactsIngestError: BBError, Equatable, CustomStringConvertible {
  /// Checked BEFORE the reindex deletes anything. See `reindexAll`.
  case notAuthorized(ContactsAuthorization)

  public var description: String {
    switch self {
    case .notAuthorized(let status):
      "Contacts access is \(status). Grant it in System Settings › Privacy & "
        + "Security › Contacts, then refresh."
    }
  }
}

public struct ContactsIngestResult: Sendable, Equatable {
  public let indexed: Int
  public let skipped: Int
  public let duration: Duration

  public init(indexed: Int, skipped: Int, duration: Duration) {
    self.indexed = indexed
    self.skipped = skipped
    self.duration = duration
  }
}

public actor ContactsIngestor {

  private let index: ContactIndex
  private let batchSize: Int

  public init(index: ContactIndex, batchSize: Int = 200) {
    self.index = index
    self.batchSize = batchSize
  }

  public static var authorizationStatus: ContactsAuthorization {
    #if canImport(Contacts)
      switch CNContactStore.authorizationStatus(for: .contacts) {
      case .authorized: .authorized
      case .denied: .denied
      case .restricted: .restricted
      case .notDetermined: .notDetermined
      @unknown default: .notDetermined
      }
    #else
      .unavailable
    #endif
  }

  #if canImport(Contacts)

    /// Exactly the keys needed to build an index entry.
    ///
    /// `CNContactImageDataKey` and `CNContactThumbnailImageDataKey` are deliberately absent.
    /// Requesting either here is what makes the current implementation expensive, and the
    /// avatar endpoint fetches image data per contact on demand instead.
    ///
    /// Computed rather than stored: `[any CNKeyDescriptor]` is not Sendable, so as a static
    /// stored property it would be shared mutable state across isolation domains. Building
    /// the array per call costs nothing next to the fetch it configures.
    static var indexKeys: [any CNKeyDescriptor] {
      [
        CNContactIdentifierKey as any CNKeyDescriptor,
        CNContactGivenNameKey as any CNKeyDescriptor,
        CNContactFamilyNameKey as any CNKeyDescriptor,
        CNContactNicknameKey as any CNKeyDescriptor,
        CNContactOrganizationNameKey as any CNKeyDescriptor,
        CNContactPhoneNumbersKey as any CNKeyDescriptor,
        CNContactEmailAddressesKey as any CNKeyDescriptor,
        CNContactBirthdayKey as any CNKeyDescriptor,
      ]
    }

    /// Streams the whole address book into the index.
    ///
    /// Two things keep this flat in memory: the enumeration hands us one contact at a time
    /// and we never retain the CNContact past mapping it, and each batch is wrapped in an
    /// autorelease pool. Foundation enumerations autorelease heavily, so without the pool
    /// this shows up as classic sawtooth growth across a long ingest.
    @discardableResult
    public func reindexAll() async throws -> ContactsIngestResult {
      let started = ContinuousClock.now

      // BEFORE the delete below, and that order is the whole point.
      //
      // The delete is unconditional and `enumerateContacts` throws when access is denied,
      // so without this the sequence on an unauthorized process is: wipe every address-book
      // contact, then fail. `ContactsService.start` runs this with `try?`, so nothing
      // surfaced — the index was simply empty afterwards, every message showed a phone
      // number instead of a name, and the log said nothing at all. Revoking Contacts in
      // System Settings did it, and so did anything running the server without a TCC grant,
      // which includes every unbundled `swift run`: TCC attributes a shell-spawned process
      // to the terminal rather than to us, so the grant this app holds does not apply.
      //
      // Refusing to start is strictly better than emptying the index. Stale names are worth
      // more than no names, and the previous ingest's results stay usable until access
      // comes back.
      let store = CNContactStore()

      // `.notDetermined` is not a denial — it means macOS has never asked. Requesting is
      // what puts the prompt on screen, and it is the ONLY thing that does: the guard below
      // deliberately never reaches the store, so without this the app can no longer trigger
      // its own permission prompt at all. That regression was introduced by the guard and
      // caught by running the app rather than by any test, because a test bundle's TCC
      // status is whatever the host happens to have.
      if Self.authorizationStatus == .notDetermined {
        _ = try? await store.requestAccess(for: .contacts)
      }

      let authorization = Self.authorizationStatus
      guard authorization == .authorized else {
        throw ContactsIngestError.notAuthorized(authorization)
      }

      // Which account each contact lives in, resolved ONCE before the main pass.
      //
      // Contacts.framework will tell you a contact's container only by predicate, so asking
      // per contact would be one round trip each. Going the other way — enumerate each
      // container fetching identifiers and nothing else — is a single cheap pass whose cost
      // does not grow with how much data a contact carries.
      let accounts = Self.accountsByIdentifier(store: store)

      let request = CNContactFetchRequest(keysToFetch: Self.indexKeys)
      request.unifyResults = true
      // We never read image data, so tell the framework not to prepare it.
      request.mutableObjects = false

      // Replace rather than merge: a contact deleted in the address book has to disappear
      // here too, and a full reindex has no deletion event to observe.
      try await index.removeAll(source: .macOS)

      let index = self.index
      let batchSize = self.batchSize
      var batch: [ContactRecord] = []
      batch.reserveCapacity(batchSize)
      var indexed = 0
      var skipped = 0
      var thrown: (any Error)?

      // The enumeration callback is synchronous and cannot await, so each full batch is
      // written with the blocking database path rather than accumulated. That is the
      // difference between peak memory being one batch and being the whole address book —
      // which is the entire point of streaming rather than calling getAllContacts().
      try autoreleasepool {
        try store.enumerateContacts(with: request) { contact, stop in
          autoreleasepool {
            guard let record = Self.map(contact, accounts: accounts) else {
              skipped += 1
              return
            }
            batch.append(record)
            guard batch.count >= batchSize else { return }
            do {
              try index.upsertSynchronously(batch)
              indexed += batch.count
              batch.removeAll(keepingCapacity: true)
            } catch {
              // enumerateContacts' callback cannot throw; carry the error out.
              thrown = error
              stop.pointee = true
            }
          }
        }
      }
      if let thrown { throw thrown }

      if !batch.isEmpty {
        try index.upsertSynchronously(batch)
        indexed += batch.count
      }
      await index.invalidateCache()

      return ContactsIngestResult(
        indexed: indexed, skipped: skipped, duration: ContinuousClock.now - started
      )
    }

    /// Re-indexes only the identifiers that changed.
    ///
    /// CNContactStoreDidChange does not say WHAT changed, only that something did. The
    /// caller supplies identifiers it cares about — in practice the addresses seen in recent
    /// messages — so a change notification does not force a full reload the way the current
    /// `contactsLoaded = false` flag does.
    @discardableResult
    public func reindex(identifiers: [String]) async throws -> ContactsIngestResult {
      guard !identifiers.isEmpty else {
        return ContactsIngestResult(indexed: 0, skipped: 0, duration: .zero)
      }

      let started = ContinuousClock.now
      let store = CNContactStore()
      let predicate = CNContact.predicateForContacts(withIdentifiers: identifiers)

      var records: [ContactRecord] = []
      var missing = Set(identifiers)
      let accounts = Self.accountsByIdentifier(store: store)

      try autoreleasepool {
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: Self.indexKeys)
        for contact in contacts {
          missing.remove(contact.identifier)
          if let record = Self.map(contact, accounts: accounts) { records.append(record) }
        }
      }

      try await index.upsert(records)
      // Anything the store no longer returns was deleted.
      try await index.remove(ids: Array(missing))

      return ContactsIngestResult(
        indexed: records.count, skipped: missing.count,
        duration: ContinuousClock.now - started
      )
    }

    /// Image data for one contact, fetched on demand.
    ///
    /// Separated from ingest deliberately — this is the only place image bytes are ever
    /// loaded, and it loads exactly one contact's.
    public func imageData(identifier: String, thumbnail: Bool = true) throws -> Data? {
      let store = CNContactStore()
      let keys: [any CNKeyDescriptor] = [
        (thumbnail ? CNContactThumbnailImageDataKey : CNContactImageDataKey) as any CNKeyDescriptor
      ]
      return try autoreleasepool {
        let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
        return thumbnail ? contact.thumbnailImageData : contact.imageData
      }
    }

    /// Every contact identifier in the address book, mapped to the account holding it.
    ///
    /// Best-effort by design: a container that refuses to enumerate is skipped rather than
    /// failing the whole ingest. An unknown account costs a label; a failed ingest costs every
    /// name in every conversation.
    static func accountsByIdentifier(store: CNContactStore) -> [String: ContactAccount] {
      var result: [String: ContactAccount] = [:]
      guard let containers = try? store.containers(matching: nil) else { return result }

      for container in containers {
        let account = ContactAccount.infer(
          containerType: Self.name(of: container.type),
          name: container.name
        )
        let predicate = CNContact.predicateForContactsInContainer(
          withIdentifier: container.identifier
        )
        // Identifier only. This pass exists to learn WHERE contacts are, and asking for
        // anything else would double the cost of the ingest to answer a question about
        // one column.
        let keys = [CNContactIdentifierKey as any CNKeyDescriptor]
        guard
          let contacts = try? store.unifiedContacts(
            matching: predicate, keysToFetch: keys
          )
        else { continue }

        for contact in contacts where result[contact.identifier] == nil {
          result[contact.identifier] = account
        }
      }
      return result
    }

    private static func name(of type: CNContainerType) -> String {
      switch type {
      case .local: "local"
      case .exchange: "exchange"
      case .cardDAV: "cardDAV"
      case .unassigned: "unassigned"
      @unknown default: "unknown"
      }
    }

    static func map(
      _ contact: CNContact,
      accounts: [String: ContactAccount] = [:]
    ) -> ContactRecord? {
      let phones = contact.phoneNumbers.map(\.value.stringValue)
      let emails = contact.emailAddresses.map { $0.value as String }
      // A contact with no addresses can never be looked up by one, so indexing it costs a
      // row and buys nothing.
      guard !phones.isEmpty || !emails.isEmpty else { return nil }

      let display = [contact.givenName, contact.familyName]
        .filter { !$0.isEmpty }
        .joined(separator: " ")

      var birthday: String?
      if let components = contact.birthday, let month = components.month, let day = components.day {
        // Year is frequently absent in address books; store what is there.
        birthday =
          components.year.map { String(format: "%04d-%02d-%02d", $0, month, day) }
          ?? String(format: "--%02d-%02d", month, day)
      }

      return ContactRecord(
        id: ContactIndex.addressBookPrefix + contact.identifier,
        source: .macOS,
        firstName: contact.givenName.isEmpty ? nil : contact.givenName,
        lastName: contact.familyName.isEmpty ? nil : contact.familyName,
        displayName: display.isEmpty
          ? (contact.organizationName.isEmpty ? nil : contact.organizationName)
          : display,
        nickname: contact.nickname.isEmpty ? nil : contact.nickname,
        birthday: birthday,
        externalID: contact.identifier,
        phoneNumbers: phones,
        emailAddresses: emails,
        account: accounts[contact.identifier]
      )
    }

  #else

    @discardableResult
    public func reindexAll() async throws -> ContactsIngestResult {
      ContactsIngestResult(indexed: 0, skipped: 0, duration: .zero)
    }

    @discardableResult
    public func reindex(identifiers: [String]) async throws -> ContactsIngestResult {
      ContactsIngestResult(indexed: 0, skipped: 0, duration: .zero)
    }

    public func imageData(identifier: String, thumbnail: Bool = true) throws -> Data? { nil }

  #endif
}

extension ContactsIngestError {
  public var code: String {
    switch self {
    case .notAuthorized: "contacts.not_authorized"
    }
  }

  public var domain: String { "Contacts" }

  public var isUserFacing: Bool { true }

  public var title: String { "Contacts access is not granted" }

  public var body: String { description }
}
