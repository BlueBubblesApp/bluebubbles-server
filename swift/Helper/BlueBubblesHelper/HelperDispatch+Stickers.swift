//  HelperDispatch+Stickers
//  Stickers: placing one on a message, and adding one to this Mac's store.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func sendSticker(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    var placement = StickerPlacement.centered
    if let x = data.double(.xScalar) { placement.xScalar = x }
    if let y = data.double(.yScalar) { placement.yScalar = y }
    if let scale = data.double(.scale) { placement.scale = scale }
    if let rotation = data.double(.rotation) { placement.rotation = rotation }
    if let width = data.double(.parentPreviewWidth) { placement.parentPreviewWidth = width }
    let sent = try await bridge.sendSticker(
      SendStickerRequest(
        chat: try data.chat(),
        filePath: try data.string(.filePath),
        target: try data.message(.selectedMessageGuid),
        partIndex: data.integer(.partIndex),
        placement: placement,
        asTapback: data.flag(.tapback),
        isRemoval: data.flag(.remove)
      )
    )
    return [.identifier: sent.guid.rawValue]
  }

  @MainActor
  static func saveSticker(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    let saved = try await bridge.saveSticker(
      SaveStickerRequest(
        filePath: try data.string(.filePath),
        name: data.optionalString(.name),
        accessibilityName: data.optionalString(.accessibilityName)
      )
    )
    return [
      .identifier: saved.identifier,
      .externalURI: saved.externalURI,
      .byteCount: String(saved.byteCount),
    ]
  }
}
