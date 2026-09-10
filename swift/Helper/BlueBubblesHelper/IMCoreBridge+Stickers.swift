//  IMCoreBridge+Stickers
//  Reading and writing the user's sticker library. `StickerLibrary`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  /// Adds a sticker to this Mac's sticker store, so it appears in the picker.
  ///
  /// Nothing is sent. This runs in the helper rather than in the server because the store
  /// lives in an app-group container Messages is entitled to and the server is not; reading
  /// the same store needs no helper, and does not use this path.
  ///
  /// The bytes are read here rather than passed across the socket as base64 for the reason
  /// every other attachment route has one: a sticker is an image, images are large, and the
  /// wire protocol is a line-delimited JSON socket.
  public func saveSticker(_ request: SaveStickerRequest) async throws -> SavedSticker {
    guard FileManager.default.fileExists(atPath: request.filePath) else {
      throw PrivateAPIErrorShim.rejected("no file at \(request.filePath)")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: request.filePath))
    guard !data.isEmpty else {
      throw PrivateAPIErrorShim.rejected("that file is empty")
    }
    return try translating {
      let donated = try IMStickerStore.donateToRecents(
        data: data, name: request.name, accessibilityName: request.accessibilityName
      )
      return SavedSticker(
        identifier: donated.identifier.uuidString,
        externalURI: donated.externalURI,
        byteCount: data.count
      )
    }
  }
}
