//  ContactsService
//  Indexes the address book, and publishes the ingestor the contact interface refreshes with.
//
//  Every pass this service runs is on ONE task: the start-up pass, then one per settled run
//  of `CNContactStoreDidChange`, with whatever settles during a pass coalesced into a single
//  pass after it, so two passes never read the whole address book side by side or commit in
//  whichever order they happen to finish.

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

  /// One pass over the address book. `reindexAll` in every server; a test supplies one that
  /// records what it was asked to do, because a test process cannot drive the real
  /// `CNContactStore`.
  typealias Reindex = @Sendable (ContactsIngestor) async throws -> ContactsIngestResult

  private let logger: Logger
  /// ONE per start, published for `contact/refresh` and used by every pass this service
  /// runs, so a refresh and a pass meet on the same actor and run one after the other.
  private let ingestor: ContactsIngestor
  /// Where the ingestor is handed over, and taken back on stop.
  private let published: PublishedSlot<ContactsIngestor>
  private let reindex: Reindex
  private let debounce: Duration
  /// Every pass this service runs: the start-up one, then one per settled change. ONE task,
  /// so two passes of this service can never overlap, and a stop that waits for it waits
  /// for whichever pass is in progress.
  private let passes = OwnedTask()

  /// How long the address book has to be quiet before a change is acted on.
  ///
  /// `CNContactStoreDidChange` fires per change, not per edit session: linking an account
  /// delivers a burst as each contact lands, and a full re-index per notification would walk
  /// the whole address book dozens of times during one sync. Long enough to let a sync finish,
  /// short enough that a single edit is reflected while the person who made it is still
  /// thinking about it.
  static let changeDebounce: Duration = .seconds(10)

  init(host: Host) {
    self.init(
      host: host, debounce: Self.changeDebounce, reindex: { try await $0.reindexAll() })
  }

  /// The seams a test needs: a shorter debounce, and a pass it can observe.
  init(host: Host, debounce: Duration, reindex: @escaping Reindex) {
    self.logger = host.logger
    self.ingestor = ContactsIngestor(index: host.contacts)
    self.published = PublishedSlot(
      publish: { await host.publish(contactsIngestor: $0) },
      withdraw: { await host.withdrawContactsIngestor() })
    self.reindex = reindex
    self.debounce = debounce
  }

  func start() async throws {
    // Published, not just used: `ContactInterface.refresh` (the API route and the app's
    // "Refresh from Address Book" button) reaches the address book through this instance.
    await published.publish(ingestor)

    // Subscribed BEFORE the first pass, so a change made while it reads is not missed. The
    // pass may already have read past the contact that changed.
    let changes = Self.addressBookChanges().debounce(
      for: debounce,
      // Coalesced: everything that settles while a pass runs is ONE pass after it, however
      // many quiet periods it spanned. Each pass re-reads the whole address book, so a
      // second queued behind the first would only repeat it.
      bufferingPolicy: .bufferingNewest(1))

    let ingestor = self.ingestor
    let reindex = self.reindex
    let logger = self.logger

    // Deliberately not awaited to completion: a large address book takes a while, and
    // blocking startup on it would delay everything behind this service for no reason.
    // Names simply fill in when the pass commits.
    passes.run {
      guard await Self.pass(.startUp, ingestor: ingestor, reindex: reindex, logger: logger)
      else { return }
      for await _ in changes {
        guard !Task.isCancelled else { return }
        guard
          await Self.pass(.addressBookChanged, ingestor: ingestor, reindex: reindex, logger: logger)
        else { return }
      }
    }
  }

  /// Why a pass runs, which is all that differs between them: what is logged.
  private enum Occasion {
    case startUp
    case addressBookChanged
  }

  /// One pass, reported. Returns false when it was cancelled, which ends the loop.
  private static func pass(
    _ occasion: Occasion, ingestor: ContactsIngestor, reindex: Reindex, logger: Logger
  ) async -> Bool {
    do {
      let result = try await reindex(ingestor)
      logger.info(
        occasion == .startUp
          ? "Indexed the address book" : "Re-indexed the address book after it changed",
        metadata: [
          "indexed": .stringConvertible(result.indexed),
          "skipped": .stringConvertible(result.skipped),
        ])
    } catch is CancellationError {
      // Ordinary: `stop()` cancels the pass in progress.
      return false
    } catch let error as ContactsIngestError {
      // Reported, not swallowed: the single most likely failure (no Contacts permission)
      // would otherwise produce a server that shows phone numbers for every message with no
      // way to tell why. Not an alert: running without Contacts is a supported
      // configuration, and the Permissions page is where a user acts on it.
      logger.warning(
        "Could not index the address book",
        metadata: [
          "reason": .string(String(describing: error))
        ])
    } catch {
      // Warning, not an alert: the address book changing while Contacts access is being
      // revoked is the likely cause, and the Permissions page is where that is acted on.
      logger.warning(
        "The address-book index failed",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }
    return true
  }

  /// A tick per `CNContactStoreDidChange`, observed from the moment this is called.
  ///
  /// **Without this, a removal is only noticed at start-up or on a manual Refresh.** A full
  /// pass replaces every address-book row with what Contacts hands over, so a contact
  /// deleted, or an entire account unlinked, simply stops being returned; but only if a pass
  /// runs. A server left running for weeks would go on serving contacts the Mac no longer
  /// had, and on turning their handles into names.
  ///
  /// Debounced by the caller rather than acted on at once, because the notification says only
  /// that SOMETHING changed, never what: unlinking an account delivers one per contact removed.
  ///
  /// There is no feedback loop to guard against. This server only ever READS the contact
  /// store; the index it writes is its own table, which no notification watches.
  ///
  /// A stream of bare ticks rather than `NotificationCenter.notifications(named:)`, because
  /// `Notification` is not `Sendable` and nothing here wants its contents. Yielding `Void` also
  /// lets the observer be removed explicitly when the stream is torn down.
  private static func addressBookChanges() -> AsyncStream<Void> {
    AsyncStream<Void> { continuation in
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
  }

  /// Waited for, so a restart's pass never runs beside this one's, and then the ingestor is
  /// taken back: a `contact/refresh` after this answers that the service is not running
  /// rather than reading the address book on its behalf.
  func stop() async {
    await passes.stop()
    await published.withdraw()
  }

  var health: ServiceHealth {
    get async {
      passes.isRunning ? .running : .inactive(reason: ServiceHealth.RoutineReason.notStarted)
    }
  }

  /// The pass loop: the start-up pass leads into the watch, so the loop is alive for as long
  /// as the index is being kept in agreement with an address book that changes under a
  /// running server.
  var isAlive: Bool { get async { passes.isRunning } }
}
