//  ContactsService
//  Indexes the address book, and publishes the ingestor the contact interface refreshes with.

import BBBuiltIns
import BBContacts
import BBInterfaces
import BBServiceKit
import Logging

actor ContactsService: Service {
  static let manifest = BuiltInManifests.contacts

  /// What this service touches, rather than the container that holds it.
  typealias Host = any ContactIndexProviding & LoggerProviding & ContactsIngestorPublishing

  private let host: Host
  private let contacts: ContactIndex
  private let logger: Logger
  /// Held so the ingest can be cancelled. `Task.detached` with nothing holding it meant
  /// `stop()` could not stop it: restarting the service — which a settings change now
  /// genuinely does — left the previous reindex running and started a second one on top,
  /// two writers walking the same address book.
  private var ingest: Task<Void, Never>?

  init(host: Host) {
    self.host = host
    self.contacts = host.contacts
    self.logger = host.logger
  }

  func start() async throws {
    // Deliberately not awaited to completion: a large address book takes a while, and
    // blocking startup on it would delay everything behind this service for no reason.
    // Names simply fill in as the ingest progresses.
    let contacts = self.contacts
    let logger = self.logger

    // Published, not just used. The startup reindex built one of these locally and threw it
    // away, so `ContactInterface` held nil and every `contact/refresh` — the API route and
    // the app's "Refresh from Address Book" button — refused with "contact access has not
    // been granted", whatever the actual permission was. One instance, shared.
    let ingestor = ContactsIngestor(index: contacts)
    await host.publish(contactsIngestor: ingestor)

    ingest?.cancel()
    ingest = Task {
      do {
        let result = try await ingestor.reindexAll()
        logger.info(
          "Indexed the address book",
          metadata: [
            "indexed": .stringConvertible(result.indexed),
            "skipped": .stringConvertible(result.skipped),
          ])
      } catch let error as ContactsIngestError {
        // Reported, not swallowed. This was `try?`, so the single most likely failure
        // — no Contacts permission — produced an empty index, no log line, and a
        // server that showed phone numbers for every message with no way to tell why.
        // Not an alert: running without Contacts is a supported configuration, and
        // the Permissions page is where a user acts on it.
        logger.warning(
          "Could not index the address book",
          metadata: [
            "reason": .string(String(describing: error))
          ])
      } catch is CancellationError {
        // Ordinary: `stop()` cancels the ingest.
      } catch {
        logger.error(
          "The address-book index failed",
          metadata: [
            "error": .string(String(describing: error))
          ])
      }
    }
  }

  func stop() async {
    ingest?.cancel()
    ingest = nil
  }

  var health: ServiceHealth {
    get async { ingest != nil ? .running : .inactive(reason: "not started") }
  }
}
