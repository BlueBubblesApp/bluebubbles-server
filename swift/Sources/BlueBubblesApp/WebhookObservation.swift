//  WebhookObservation
//  Delivery outcomes and the registered list, followed for the life of the server.
//
//  The API & Webhooks page re-read everything on a ten-second sleep, the one timer the app
//  had, because the tracker had nothing to follow and the table could be written by a
//  client over HTTP with nothing in this process hearing about it. Both now stream: the
//  tracker yields its table on every recorded outcome, and GRDB re-runs the registration
//  read after every commit to the table, whichever path wrote it.

import BBEvents
import BBInterfaces
import Foundation

extension AppModel {

  /// Follows both streams. Cancelled by `stopFollowingServer`.
  ///
  /// Subscribed before the seed read, so no outcome falls between them: the same order
  /// `followTools` uses. The registration follow needs no seed: the observation's first
  /// element is the current table.
  func followWebhooks(_ directory: WebhookDirectory) {
    webhookDeliveriesTask?.cancel()
    webhookDeliveriesTask = Task { [weak self] in
      let changes = await directory.deliveries.changes()
      self?.webhookDeliveries = await directory.deliveries.all()
      for await table in changes {
        self?.webhookDeliveries = table
      }
    }

    webhookRegistrationsTask?.cancel()
    webhookRegistrationsTask = Task { [weak self] in
      do {
        for try await _ in directory.registrations() {
          // The page reads the rows itself, through `ScreenModel`, so a failed read is
          // reported there. This only says "something changed".
          self?.webhookRegistrationsVersion += 1
        }
      } catch {
        // The observation itself failed, which means the database did. The page's next
        // read fails the same way and says so; there is nothing to add here.
      }
    }
  }
}
