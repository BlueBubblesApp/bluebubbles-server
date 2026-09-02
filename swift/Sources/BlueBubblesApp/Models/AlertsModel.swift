//  AlertsModel
//  The alert drawer's state: what has been raised, and how much of it is unread.

import BBDiagnostics
import Foundation
import Observation

@Observable
@MainActor
final class AlertsModel {

  private(set) var items: [UserAlert] = []
  private(set) var unreadCount = 0

  /// Called whenever the unread count moves, so the Dock badge follows it.
  var onUnreadCountChanged: (@MainActor () async -> Void)?

  private var center: AlertCenter?
  private var streamTask: Task<Void, Never>?

  func attach(_ center: AlertCenter) {
    self.center = center
    streamTask?.cancel()
    streamTask = Task { [weak self] in
      // Seeded first, so the drawer is populated on open rather than only after the
      // next alert arrives.
      let existing = await center.all(limit: 200)
      let unread = await center.badgeCount()
      await MainActor.run {
        self?.items = existing
        self?.unreadCount = unread
      }

      for await alert in await center.stream() {
        await MainActor.run {
          self?.items.insert(alert, at: 0)
          self?.unreadCount += 1
          Task { await self?.onUnreadCountChanged?() }
        }
      }
    }
  }

  func detach() {
    streamTask?.cancel()
    streamTask = nil
    center = nil
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
  /// without moving the badge — arithmetic here would drift out of step with it on the
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
