//  WebhooksModel
//  Delivery outcomes and the registered list, followed for the life of the server.
//
//  The API & Webhooks page re-read everything on a ten-second sleep, the one timer the app
//  had, because the tracker had nothing to follow and the table could be written by a
//  client over HTTP with nothing in this process hearing about it. Both stream: the tracker
//  yields its table on every recorded outcome, and GRDB re-runs the registration read after
//  every commit to the table, whichever path wrote it.
//
//  The two halves are held differently on purpose. The outcomes ARE the state, so they are
//  held here. The registrations are only counted: the page reads the rows itself through its
//  own `ScreenModel`, so a read that fails lands where the page can say so, and this model
//  hands it a version to key that read on.

import BBCore
import BBEvents
import BBInterfaces
import Foundation
import Observation

@Observable
@MainActor
final class WebhooksModel {

  /// What each webhook's last delivery did, by webhook id. Empty when there is no server.
  private(set) var deliveries: [Int64: WebhookDeliveryState] = [:]
  /// Bumped on every change to the webhook table, so the page's own read can be keyed on
  /// it. A counter rather than the rows: the read is the page's, and it throws. `detach`
  /// leaves it where it is: it only ever moves forward.
  private(set) var registrationsVersion = 0

  private let deliveryStream = OwnedTask()
  private let registrationStream = OwnedTask()

  /// Follows both streams.
  ///
  /// The outcomes are subscribed BEFORE their seed read, so an outcome recorded between the
  /// two is not lost. The registrations need no seed: a GRDB observation's first element is
  /// the current table, so the counter moves once as soon as it attaches.
  func attach(_ directory: WebhookDirectory) {
    let tracker = directory.deliveries
    deliveryStream.run { @MainActor [weak self] in
      let changes = await tracker.changes()
      guard let model = self else { return }
      model.deliveries = await tracker.all()
      for await table in changes {
        guard let model = self else { return }
        model.deliveries = table
      }
    }
    registrationStream.run { @MainActor [weak self] in
      await FollowTable.countChanges(
        named: "webhookRegistrations", of: { directory.registrations() }
      ) {
        guard let model = self else { return false }
        model.registrationsVersion += 1
        return true
      }
    }
  }

  /// Stops both follows and clears the outcomes, so a stopped server shows none.
  func detach() {
    deliveryStream.cancel()
    registrationStream.cancel()
    deliveries = [:]
  }
}
