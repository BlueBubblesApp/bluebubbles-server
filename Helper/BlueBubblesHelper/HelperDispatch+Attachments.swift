//  HelperDispatch+Attachments
//  Attachments the daemon purged and has to fetch again.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func downloadPurgedAttachment(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [
      .path: try await bridge.downloadPurgedAttachment(
        guid: try data.string(.attachmentGuid)
      )
    ]
  }
}
