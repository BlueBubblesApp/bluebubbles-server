//  ContactsIngest
//  Streaming ingest from CNContactStore into the index.
//
//  `enumerateContacts` streams one contact at a time, only the keys needed to index are
//  requested, image data is never fetched in the bulk pass, and batches are flushed to
//  SQLite so peak memory is the batch rather than the address book. Fetching every contact
//  with every property (full-resolution images included) is the single biggest
//  allocation a server like this can make.
//
//  The batches are flushed into a REBUILD beside the live index, not into the index itself,
//  and the rebuild replaces it in one transaction at the end; see
//  `ContactIndex.beginRebuild(of:)`. Nothing that reads the index sees a pass in progress.
//
//  **Reading the address book never asks for it.** A pass that prompted put the dialog on
//  screen the moment `ContactsService` started, ahead of everything onboarding had to say.
//  Asking is `PermissionsService.request`'s job; here a process without the grant refuses.
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
  /// Contacts.framework is unavailable. Not an error: the server runs fine without it,
  /// clients just see phone numbers instead of names.
  case unavailable
}

public enum ContactsIngestError: BBError, Equatable, CustomStringConvertible {
  /// Checked BEFORE the reindex reads anything. See `reindexAll`.
  case notAuthorized(ContactsAuthorization)

  public var description: String {
    switch self {
    case .notAuthorized(.notDetermined):
      "Contacts access has not been asked for yet. Request it under Settings › Permissions, "
        + "then refresh."
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
  /// One full pass at a time; see `reindexAll`.
  private let passes = OneAtATime()

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
    /// Requesting either here is what makes the reference expensive, and the
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

    /// Streams the whole address book into the index, replacing what it held.
    ///
    /// Two things keep this flat in memory: the enumeration hands us one contact at a time
    /// and we never retain the CNContact past mapping it, and each batch is wrapped in an
    /// autorelease pool. Foundation enumerations autorelease heavily, so without the pool
    /// this shows up as classic sawtooth growth across a long ingest.
    ///
    /// **The pass runs on a thread of its own** (`onOwnThread`), never on the cooperative
    /// pool. `enumerateContacts` is synchronous and a whole address book takes about thirty
    /// seconds on a slow Mac; held on the pool that is one of only two threads on a two-core
    /// machine, with every HTTP request and service start queued behind it.
    ///
    /// **Two calls on one ingestor run one after the other**, never interleaved: the second
    /// waits for the first to commit (`OneAtATime`). Overlapping passes would each be correct,
    /// because each stages apart, but on a spinning disk two concurrent enumerations take
    /// twice as long as one after the other, and the change notification that follows the
    /// first index is exactly when a second arrives. Calls on two ingestors over one index
    /// may still overlap, and each commits a whole address book.
    @discardableResult
    public func reindexAll() async throws -> ContactsIngestResult {
      let started = ContinuousClock.now

      // Before anything else, so an unauthorised process refuses with a reason that names
      // the permission rather than with whatever `enumerateContacts` throws.
      //
      // The rebuild below would leave the index untouched either way, which is the property
      // that matters: an unauthorised pass used to delete every address-book contact first
      // and THEN fail, and every message went on showing a phone number instead of a name.
      // Revoking Contacts in System Settings did it, and so did anything running the server
      // without a TCC grant, which includes every unbundled `swift run`: TCC attributes a
      // shell-spawned process to the terminal rather than to us, so the grant this app holds
      // does not apply. Stale names are worth more than no names.
      //
      // `.notDetermined` refuses like the rest. It means macOS has never asked, and asking is
      // not this type's decision; see the header.
      let authorization = Self.authorizationStatus
      guard authorization == .authorized else {
        throw ContactsIngestError.notAuthorized(authorization)
      }

      let index = self.index
      let batchSize = self.batchSize
      let (indexed, skipped) = try await passes.run {
        // Replace rather than merge: a contact deleted in the address book has to disappear
        // here too, and a full reindex has no deletion event to observe. Built beside the
        // live index and swapped in whole, so the replacement is never seen half-done.
        let rebuild = try index.beginRebuild(of: .macOS)
        let counts = try await onOwnThread { isCancelled in
          try Self.stream(into: rebuild, batchSize: batchSize, isCancelled: isCancelled)
        }
        await index.invalidateCache()
        return counts
      }

      return ContactsIngestResult(
        indexed: indexed, skipped: skipped, duration: ContinuousClock.now - started
      )
    }

    /// The whole enumeration, synchronous, for `onOwnThread`: reads every contact into
    /// `rebuild` and commits it, or discards it and throws.
    ///
    /// The enumeration callback is synchronous and cannot await, so each full batch is
    /// written with the blocking database path rather than accumulated. That is the
    /// difference between peak memory being one batch and being the whole address book:
    /// which is the entire point of streaming rather than calling getAllContacts().
    static func stream(
      into rebuild: ContactIndex.Rebuild,
      batchSize: Int,
      isCancelled: () -> Bool
    ) throws -> (indexed: Int, skipped: Int) {
      let store = CNContactStore()

      // Which account each contact lives in, resolved ONCE before the main pass.
      //
      // Contacts.framework will tell you a contact's container only by predicate, so asking
      // per contact would be one round trip each. Going the other way (enumerate each
      // container fetching identifiers and nothing else) is a single cheap pass whose cost
      // does not grow with how much data a contact carries.
      let accounts = accountsByIdentifier(store: store)

      let request = CNContactFetchRequest(keysToFetch: indexKeys)
      request.unifyResults = true
      // We never read image data, so tell the framework not to prepare it.
      request.mutableObjects = false

      var batch: [ContactRecord] = []
      batch.reserveCapacity(batchSize)
      var indexed = 0
      var skipped = 0
      var thrown: (any Error)?

      do {
        try autoreleasepool {
          try store.enumerateContacts(with: request) { contact, stop in
            autoreleasepool {
              // CANCELLATION, checked per contact, because nothing else in this loop can see
              // it: the enumeration is synchronous and on a thread with no task, so the flag
              // `onOwnThread` hands over is the only way a stop reaches it. Without this a
              // stopped service's pass would read the rest of the address book before
              // noticing, and a restart would wait for all of it.
              guard !isCancelled() else {
                thrown = CancellationError()
                stop.pointee = true
                return
              }
              guard let record = map(contact, accounts: accounts) else {
                skipped += 1
                return
              }
              batch.append(record)
              guard batch.count >= batchSize else { return }
              do {
                try rebuild.add(batch)
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

        // Not committed on cancellation: a pass stopped part-way has read part of the address
        // book, and swapping that in would drop every contact it had not reached.
        if isCancelled() { throw CancellationError() }

        if !batch.isEmpty {
          try rebuild.add(batch)
          indexed += batch.count
        }
        try rebuild.commit()
      } catch {
        rebuild.discard()
        throw error
      }
      return (indexed, skipped)
    }

    /// Re-indexes only the identifiers that changed.
    ///
    /// CNContactStoreDidChange does not say WHAT changed, only that something did. The
    /// caller supplies identifiers it cares about (in practice the addresses seen in recent
    /// messages) so a change notification does not force a full reload the way the current
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
    /// Separated from ingest deliberately: this is the only place image bytes are ever
    /// loaded, and it loads exactly one contact's.
    ///
    /// `nonisolated`, as `imageData(identifiers:thumbnail:)` is and for the same reason: a
    /// picture read never waits for an index pass to finish.
    nonisolated public func imageData(identifier: String, thumbnail: Bool = true) throws -> Data? {
      let store = CNContactStore()
      let keys: [any CNKeyDescriptor] = [
        (thumbnail ? CNContactThumbnailImageDataKey : CNContactImageDataKey) as any CNKeyDescriptor
      ]
      return try autoreleasepool {
        let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
        return thumbnail ? contact.thumbnailImageData : contact.imageData
      }
    }

    /// Image data for many contacts, keyed by identifier, in one fetch per hundred.
    ///
    /// For a page of contacts with their avatars, which a client asks for on every connect.
    /// One `CNContactStore` and one round trip per contact takes seconds for a few hundred
    /// contacts on a slow Mac, and longer still when the reads are isolated to this actor and
    /// queue behind an index pass. Chunked so one autorelease pool never
    /// holds more than a hundred images; a contact with no image is absent from the result.
    ///
    /// The identifiers are the index's, which come from a unified enumeration, so they are the
    /// unified contacts' identifiers that this fetch returns.
    nonisolated public func imageData(
      identifiers: [String], thumbnail: Bool = true
    ) -> [String: Data] {
      guard !identifiers.isEmpty else { return [:] }
      let store = CNContactStore()
      let imageKey = thumbnail ? CNContactThumbnailImageDataKey : CNContactImageDataKey
      var result: [String: Data] = [:]
      for chunk in identifiers.chunked(into: 100) {
        autoreleasepool {
          let keys: [any CNKeyDescriptor] = [
            CNContactIdentifierKey as any CNKeyDescriptor, imageKey as any CNKeyDescriptor,
          ]
          // A chunk that fails costs its pictures and never the page; see the caller.
          guard
            let contacts = try? store.unifiedContacts(
              matching: CNContact.predicateForContacts(withIdentifiers: chunk),
              keysToFetch: keys)
          else { return }
          for contact in contacts {
            if let data = thumbnail ? contact.thumbnailImageData : contact.imageData {
              result[contact.identifier] = data
            }
          }
        }
      }
      return result
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

    nonisolated public func imageData(identifier: String, thumbnail: Bool = true) throws -> Data? {
      nil
    }

    nonisolated public func imageData(
      identifiers: [String], thumbnail: Bool = true
    ) -> [String: Data] { [:] }

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
