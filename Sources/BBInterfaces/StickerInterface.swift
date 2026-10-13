//  StickerInterface
//  Adding a sticker to this Mac's sticker store.
//
//  The WRITE only. The reads go straight to `stickers.stickerdb` through `StickerRepository`
//  and need no helper; the write needs one, because the store's container is entitled to
//  `com.apple.stickersd.group` and this server is not. Built per call over whichever helper
//  is connected, the shape `FindMyInterface` has.

import BBPrivateAPI
import BBPrivateAPIContract
import Foundation
import Logging

public struct StickerInterface: MessagesBackedInterface {

  /// The roles this interface calls, and no more.
  public typealias Helper = any StickerLibrary

  let privateAPI: Helper?
  let logger: Logger

  public init(
    privateAPI: Helper?,
    logger: Logger = Logger(label: "bluebubbles.interface.sticker")
  ) {
    self.privateAPI = privateAPI
    self.logger = logger
  }

  /// Donates the image at `filePath` to the store, where it lands in RECENTS.
  ///
  /// Staged into Messages' container first, exactly as a sticker SEND is: the helper runs
  /// inside Messages and inherits its sandbox, so a read of the server's own uploads
  /// directory fails with EPERM. See `AttachmentStaging`.
  public func save(
    filePath: String, name: String?, accessibilityName: String?
  ) async throws -> SavedSticker {
    let api = try requirePrivateAPI(for: "saving a sticker")
    // Staged before `throughMessages`: a copy that fails is this server's, not Messages'.
    let staged = try AttachmentStaging.stage(filePath)
    return try await throughMessages {
      try await api.saveSticker(
        SaveStickerRequest(
          filePath: staged,
          name: name,
          accessibilityName: accessibilityName
        )
      )
    }
  }
}
