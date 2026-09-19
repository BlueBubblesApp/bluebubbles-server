//  ContactsService
//  Indexes the address book, and publishes the ingestor the contact interface refreshes with.

import BBBuiltIns
import BBContacts
import BBCore
import BBInterfaces
import BBServiceKit
import Contacts
import Foundation
import Logging

/// A mutable holder for a value the compiler cannot prove `Sendable`.
///
/// One use: the `NotificationCenter` observer token, which is `any NSObjectProtocol`. It is
/// written once on subscription and read once on teardown, both on the same task, so there is
/// no concurrent access to check — but there is also no way to say that in the type system.
private final class UncheckedBox<Value>: @unchecked Sendable {
  var value: Value
  init(_ value: Value) { self.value = value }
}

actor ContactsService: Service {
  static let manifest = BuiltInManifests.contacts

  /// What this service touches, rather than the container that holds it.
  typealias Host = any ContactIndexProviding & LoggerProviding & ContactsIngestorPublishing

  private let host: Host
  private let contacts: ContactIndex
  private let logger: Logger
  /// Held so the ingest can be cancelled: a restart on a settings change has to stop the
  /// previous reindex rather than start a second one on top of it, two writers walking the
  /// same address book.
  private var ingest: Task<Void, Never>?
  /// Watches the address book for changes made while this server is running. See `observe`.
  private var watcher: Task<Void, Never>?

  /// How long the address book has to be quiet before a change is acted on.
  ///
  /// `CNContactStoreDidChange` fires per change, not per edit session: linking an account
  /// delivers a burst as each contact lands, and a full re-index per notification would walk
  /// the whole address book dozens of times during one sync. Long enough to let a sync finish,
  /// short enough that a single edit is reflected while the person who made it is still
  /// thinking about it.
  static let changeDebounce: Duration = .seconds(10)

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
    // away, so `ContactInterface` held nil and every `contact/refresh` (the API route and
    // the app's "Refresh from Address Book" button) refused with "contact access has not
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
        // Reported, not swallowed: the single most likely failure (no Contacts
        // permission) would otherwise produce an empty index and a server that shows
        // phone numbers for every message with no way to tell why.
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

    // After the first ingest is under way, not before: the notification that matters is a
    // change made from here on, and the start-up pass already reads whatever is there now.
    observe()
  }

  /// Re-indexes when the address book changes underneath a running server.
  ///
  /// **Without this, a removal is only noticed at start-up or on a manual Refresh.** The index
  /// is rebuilt by `reindexAll`, which deletes every address-book row and re-inserts what
  /// Contacts hands over, so a contact deleted — or an entire account unlinked —
  /// simply stops being returned. Nothing was triggering that: `CNContactStoreDidChange`
  /// appeared in this codebase only inside a comment. A server left running for weeks went on
  /// serving contacts the Mac no longer had, and on turning their handles into names.
  ///
  /// Debounced rather than immediate, because the notification says only that SOMETHING
  /// changed, never what: unlinking an account delivers one per contact removed.
  ///
  /// There is no feedback loop to guard against. This server only ever READS the contact
  /// store; the index it writes is its own table, which no notification watches.
  private func observe() {
    let contacts = self.contacts
    let logger = self.logger
    let debounce = Self.changeDebounce
    let host = self.host

    // A stream of bare ticks rather than `NotificationCenter.notifications(named:)`, because
    // `Notification` is not `Sendable` and nothing here wants its contents: the notification
    // carries no indication of what changed, which is the whole reason this is debounced into
    // a full re-index. Yielding `Void` also lets the observer be removed explicitly when the
    // stream is torn down.
    let changes = AsyncStream<Void> { continuation in
      // Boxed because the observer token is `any NSObjectProtocol`, which is not `Sendable`
      // and so cannot be captured by the `@Sendable` termination handler directly. The box
      // is written once, here, and read once, on teardown.
      let token = UncheckedBox<(any NSObjectProtocol)?>(nil)
      token.value = NotificationCenter.default.addObserver(
        forName: .CNContactStoreDidChange, object: nil, queue: nil
      ) { _ in
        continuation.yield(())
      }
      continuation.onTermination = { _ in
        if let observer = token.value { NotificationCenter.default.removeObserver(observer) }
      }
    }

    watcher?.cancel()
    watcher = Task {
      for await _ in changes.debounce(for: debounce) {
        guard !Task.isCancelled else { return }
        // A fresh ingestor per pass, for the reason `start` publishes one: the interface
        // holds whichever is current, and a refresh has to reach the same instance.
        let ingestor = ContactsIngestor(index: contacts)
        await host.publish(contactsIngestor: ingestor)
        do {
          let result = try await ingestor.reindexAll()
          logger.info(
            "Re-indexed the address book after it changed",
            metadata: [
              "indexed": .stringConvertible(result.indexed),
              "skipped": .stringConvertible(result.skipped),
            ])
        } catch is CancellationError {
          return
        } catch {
          // Warning, not an alert: the address book changing while Contacts access is being
          // revoked is the likely cause, and the Permissions page is where that is acted on.
          logger.warning(
            "Could not re-index the address book after a change",
            metadata: ["error": .string(String(describing: error))])
        }
      }
    }
  }

  func stop() async {
    ingest?.cancel()
    ingest = nil
    watcher?.cancel()
    watcher = nil
  }

  var health: ServiceHealth {
    get async { ingest != nil ? .running : .inactive(reason: "not started") }
  }
}
