//  MetricsModel
//  What the server is doing, followed for the life of the server.
//
//  The server samples itself every few seconds and publishes a snapshot (`ServerMetrics`);
//  this is the follow. Home reads the result off this model the way it reads service health,
//  and never runs a timer of its own: a value that moves on the clock is the server's to
//  announce.
//
//  ONE stream, THREE properties, because they move at three different rates and a view
//  observes a property, not a field. The snapshot itself changes on every sample (its `at`,
//  its memory reading), and a view that reads it is re-evaluated every five seconds, which is
//  right for a figure that is live. The minute ring changes once a minute, and the sparklines
//  drawn from it should be rebuilt once a minute, not on every sample of a memory reading they
//  do not show. The message minute changes when a message arrives and at most once a minute,
//  and the activity section's read is keyed on it and on nothing else: keyed on the COUNT it
//  re-read a month of `chat.db` three ways on every sample of a busy server. Measured before
//  the split: every sample re-evaluated the whole of Home, four charts included.

import BBCore
import BlueBubblesServerCore
import Foundation
import Observation

@Observable
@MainActor
final class MetricsModel {

  /// The latest sample. Nil when there is no server. Moves on every sample: read it for a
  /// live figure, and for nothing that is drawn from the other two.
  private(set) var snapshot: ServerMetrics.Snapshot?
  /// The last hour of finished minutes, from the same stream. Moves once a minute; what the
  /// hour-window sparklines are drawn from.
  private(set) var ring: [ServerMetrics.Minute] = []
  /// The minute in which a `new-message` event last arrived, from the same stream. What
  /// the activity section's read is keyed on: it moves when a message arrives, and at most
  /// once a minute however many arrive, so a busy server does not re-read a month of
  /// `chat.db` three ways on every sample. Nil until one has.
  private(set) var newMessageMinute: Date?
  /// The count the minute above was last derived from.
  @ObservationIgnored private var newMessagesSeen = 0

  private let stream = OwnedTask()

  /// Follows the metrics: subscribes, then seeds, then applies every sample.
  ///
  /// Subscribed BEFORE the seed read, so a sample landing between the two is not lost.
  func attach(_ metrics: ServerMetrics) {
    stream.run { @MainActor [weak self] in
      let snapshots = await metrics.snapshots()
      guard let model = self else { return }
      model.apply(await metrics.snapshot)
      for await snapshot in snapshots {
        guard let model = self else { return }
        model.apply(snapshot)
      }
    }
  }

  /// Stops following and clears every figure, so a stopped server shows nothing stale.
  func detach() {
    stream.cancel()
    snapshot = nil
    ring = []
    newMessageMinute = nil
    newMessagesSeen = 0
  }

  /// Assigns each of the three properties only when its own value moved, so a view following
  /// the slow one is not woken by the fast one.
  private func apply(_ snapshot: ServerMetrics.Snapshot?) {
    self.snapshot = snapshot
    let ring = snapshot?.recent ?? []
    if ring != self.ring { self.ring = ring }
    let count = snapshot?.newMessages ?? 0
    if count != newMessagesSeen {
      newMessagesSeen = count
      if let at = snapshot?.at {
        let minute = HomeDashboard.minute(at)
        if minute != newMessageMinute { newMessageMinute = minute }
      }
    }
  }
}
