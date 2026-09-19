//  HelperDispatch+Messages
//  Changing a sent message, and reading what only IMCore knows about one.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func editMessage(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    try await bridge.editMessage(
      try data.message(),
      in: try data.chat(),
      partIndex: data.integer(.partIndex),
      newText: try data.string(.editedMessage),
      backwardCompatibilityText: try data.string(.backwardsCompatibilityMessage)
    )
    return nil
  }

  @MainActor
  static func unsendMessage(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.unsendMessage(
      try data.message(), in: try data.chat(), partIndex: data.integer(.partIndex)
    )
    return nil
  }

  @MainActor
  static func deleteMessage(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.deleteMessage(try data.message(), in: try data.chat())
    return nil
  }

  @MainActor
  static func notifyAnyways(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.notifyAnyways(try data.message(), in: try data.chat())
    return nil
  }

  @MainActor
  static func searchMessages(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    let results = try await bridge.searchMessages(
      MessageSearchRequest(query: try data.string(.query), limit: data[.limit]?.intValue)
    )
    return [.results: results.map(\.rawValue)]
  }

  @MainActor
  static func balloonBundleMediaPath(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [.path: try await bridge.balloonBundleMediaPath(for: try data.message())]
  }
}
