//  HelperDispatch+Scheduling
//  Send Later: changing or releasing a message before it goes out.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func editScheduledMessage(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.editScheduledMessage(
      try data.message(.messageGuid), in: try data.chat(), partIndex: data.integer(.partIndex),
      newText: try data.string(.editedMessage))
    return nil
  }

  @MainActor
  static func rescheduleMessage(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    guard let milliseconds = data[.scheduledFor]?.doubleValue else {
      throw PrivateAPIError.rejectedByMessages(reason: "reschedule requires 'scheduledFor'")
    }
    try await bridge.rescheduleMessage(
      try data.message(.messageGuid), in: try data.chat(),
      to: Date(timeIntervalSince1970: milliseconds / 1000))
    return nil
  }

  @MainActor
  static func sendScheduledNow(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.sendScheduledMessageNow(try data.message(.messageGuid), in: try data.chat())
    return nil
  }

  @MainActor
  static func cancelScheduledMessage(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.cancelScheduledMessage(try data.message(.messageGuid), in: try data.chat())
    return nil
  }
}
