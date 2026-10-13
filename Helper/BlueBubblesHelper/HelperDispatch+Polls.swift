//  HelperDispatch+Polls
//  Polls: creating one, changing its options, and voting.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func createPoll(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject? {
    let sent = try await bridge.createPoll(
      PollCreateRequest(
        chat: try data.chat(),
        title: data.optionalString(.title) ?? "",
        options: (data[.options]?.arrayValue ?? []).compactMap(\.stringValue)
      )
    )
    return [.identifier: sent.guid.rawValue]
  }

  @MainActor
  static func updatePoll(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject? {
    let options = (data[.options]?.arrayValue ?? []).compactMap { entry -> PollOptionSpec? in
      guard let id = entry[.id]?.stringValue, let text = entry[.text]?.stringValue else {
        return nil
      }
      return PollOptionSpec(
        id: id, text: text, creatorHandle: entry[.creatorHandle]?.stringValue,
        canBeEdited: entry[.canBeEdited]?.boolValue ?? false)
    }
    let sent = try await bridge.updatePoll(
      PollUpdateRequest(
        chat: try data.chat(), rootGUID: try data.message(.rootGuid),
        sessionID: try data.string(.sessionId),
        title: data.optionalString(.title) ?? "",
        creatorHandle: data.optionalString(.creatorHandle),
        options: options))
    return [.identifier: sent.guid.rawValue]
  }

  @MainActor
  static func votePoll(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject? {
    let sent = try await bridge.votePoll(
      PollVoteRequest(
        chat: try data.chat(),
        stateGUID: try data.message(.stateGuid),
        sessionID: try data.string(.sessionId),
        optionIDs: (data[.optionIds]?.arrayValue ?? []).compactMap(\.stringValue)
      )
    )
    return [.identifier: sent.guid.rawValue]
  }
}
