//  AccessControlObservation
//  Who is blocked, exempt, or failing, followed for the life of the server.
//
//  The Security page re-read these after its own actions and never otherwise, so an
//  automatic block that lapsed while the page was open stayed listed with "expired" beside
//  it and an Unblock button that acted on nothing. The service now streams every change,
//  including expiry, and this is the follow: the page reads `accessControl` off the model
//  the way it reads tool statuses.

import BBAuth
import Foundation

extension AppModel {

  /// Follows the service. Cancelled, and cleared, by `stopFollowingServer`.
  func followAccessControl(_ service: AccessControlService) {
    follow(
      .accessControl,
      subscribe: { await service.changes() },
      seed: { $0.accessControl = await service.snapshot() },
      apply: { $0.accessControl = $1 },
      reset: { $0.accessControl = nil })
  }
}
