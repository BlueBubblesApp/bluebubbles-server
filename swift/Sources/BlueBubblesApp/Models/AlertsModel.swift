//  AlertsModel
//  The alert drawer's state: what has been raised, and how much of it is unread.

import BBDiagnostics
import BBServiceKit
import BlueBubblesServerCore
import Foundation
import Observation

@Observable
@MainActor
final class AlertsModel {

  private(set) var items: [UserAlert] = []
  private(set) var unreadCount = 0

  /// Whether the drawer is open.
  ///
  /// On the model rather than as `@State` on the bell, for the same reason `selection` is on
  /// `AppModel`: a drawer only the bell can open is a drawer nothing else can send anyone
  /// to. The Guides page tells people the diagnostic report is under the bell, and its
  /// button opened the Logs page instead; the sentence and the button disagreed because
  /// there was no way to make them agree.
  var isDrawerPresented = false

  /// Called whenever the unread count moves, so the Dock badge follows it.
  var onUnreadCountChanged: (@MainActor () async -> Void)?

  private var center: AlertCenter?
  private var streamTask: Task<Void, Never>?
  private var dismissalTask: Task<Void, Never>?

  func attach(_ center: AlertCenter) {
    self.center = center
    streamTask?.cancel()
    streamTask = Task { [weak self] in
      // SUBSCRIBED before the seed read, not after it.
      //
      // "Each follow subscribes BEFORE its seed read so no transition falls between them"
      // is the rule every other follow in this app obeys, and this one did not: an alert
      // raised between the seed and the subscription was in neither, so a connection method
      // that raised its sign-in alert while the drawer was attaching never appeared until
      // it happened to raise again. `AsyncStream` buffers from the moment it is created, so
      // anything raised during the seed is delivered on the first iteration below.
      let alerts = await center.stream()
      // Seeded so the drawer is populated on open rather than only after the next alert.
      let existing = await center.all(limit: 200)
      let unread = await center.badgeCount()
      // No `MainActor.run` hop: `AlertsModel` is `@MainActor`, so this task already runs
      // there and the hop only made it look as though it did not.
      self?.items = existing
      self?.unreadCount = unread

      for await alert in alerts {
        // REPLACE, don't insert, when the id is already here. The centre deliberately
        // coalesces a repeated alert onto one row with an occurrence count -- "occurred 47
        // times", not 47 rows -- and broadcasts that same row each time. Inserting it undid
        // that at the only place a person sees it, and grew `items` without bound for the
        // life of the server: a flapping tunnel produced 47 identical rows here.
        if let existing = self?.items.firstIndex(where: { $0.id == alert.id }) {
          self?.items[existing] = alert
        } else {
          self?.items.insert(alert, at: 0)
        }
        // Re-read rather than incremented, for the same reason the withdrawal path re-reads
        // it: a recurrence of an already-counted alert must not count twice, and a
        // recurrence of a read one becomes unread again, which only the centre knows.
        self?.unreadCount = await center.badgeCount()
        await self?.onUnreadCountChanged?()
      }
    }
    // Withdrawals, so an alert the SERVER takes back (a connection method's sign-in link
    // once the sign-in has happened) leaves the drawer without anyone clicking it. The
    // count is re-read rather than decremented: a withdrawn alert may already have been
    // read, or be below the badge's severity.
    dismissalTask?.cancel()
    dismissalTask = Task { [weak self] in
      for await ids in await center.dismissals() {
        let removed = Set(ids)
        self?.items.removeAll { removed.contains($0.id) }
        self?.unreadCount = await center.badgeCount()
        await self?.onUnreadCountChanged?()
      }
    }
  }

  func detach() async {
    streamTask?.cancel()
    streamTask = nil
    dismissalTask?.cancel()
    dismissalTask = nil
    center = nil
    // CLEARED, like every sibling model clears what it held. Keeping the rows while
    // dropping the centre left the drawer full of a stopped server's alerts with controls
    // that no longer did anything: the unread dot calls `setRead`, which is
    // `guard let center else { return }`, so it changed nothing and said nothing; Mark All
    // Read stayed enabled and was inert; and the bell kept its badge, and the Dock badge
    // with it, for a server that is not running.
    items.removeAll()
    unreadCount = 0
    await onUnreadCountChanged?()
  }

  /// Raises an alert, through the centre when a server is up so it is persisted and badged
  /// like any other, and straight into the drawer before that.
  func raise(_ alert: UserAlert) async {
    if let center {
      await center.raise(alert)
    } else {
      items.insert(alert, at: 0)
    }
  }

  /// What a connection method is waiting on a person for, if anything.
  ///
  /// The drawer's own alerts, filtered by the prefix `ProxyService` raises them under, so
  /// the method's page and the Connection row show the same step the drawer does, and all
  /// three lose it together when the service withdraws it.
  func pendingAttention(for service: ServiceIdentifier) -> [UserAlert] {
    let prefix = ProxyAttentionAlerts.dedupeKeyPrefix(for: service)
    return items.filter { $0.dedupeKey?.hasPrefix(prefix) == true }
  }

  func markAllRead() async {
    guard let center else { return }
    await center.markAllRead()
    unreadCount = 0
    items = await center.all(limit: 200)
    await onUnreadCountChanged?()
  }

  /// Marks one alert read or unread, for the drawer's per-row toggle.
  ///
  /// Re-reads the count from the centre rather than adjusting it by one. The centre's
  /// badge counts warnings and above only, so an info alert changing state moves the list
  /// without moving the badge: arithmetic here would drift out of step with it on the
  /// first such alert and stay wrong until the next restart.
  func setRead(_ id: UUID, _ isRead: Bool) async {
    guard let center else { return }
    if isRead {
      await center.markRead([id])
    } else {
      await center.markUnread([id])
    }
    items = await center.all(limit: 200)
    unreadCount = await center.badgeCount()
    await onUnreadCountChanged?()
  }
}
