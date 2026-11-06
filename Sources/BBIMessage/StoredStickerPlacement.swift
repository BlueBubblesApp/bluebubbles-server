//  StoredStickerPlacement
//  Where a placed sticker sits on its parent, read back from `attachment.sticker_user_info`.
//
//  The column is a binary plist. Five of its keys are the geometry a client needs to draw the
//  sticker where the sender dropped it: `sxs` and `sys` (the centre, as fractions of the
//  parent's preview width), `ssa` (scale, relative to that width), `sro` (rotation, radians)
//  and `spw` (the width in points the sender laid the parent out at). They are the values the
//  send route takes, under the names it takes them (`xScalar`, `yScalar`, `scale`,
//  `rotation`, `parentPreviewWidth`), so a client can hand a received placement straight back.
//
//  **The numbers are usually STRINGS.** Measured on a macOS 27.0.1 `chat.db`: most rows
//  carrying geometry store all five as decimal strings (`"0.11932647"`), and a few as real
//  numbers. Both are read here; a reader that took only one would report no placement for
//  most stickers.
//
//  Only a sticker PLACED on a message part (association type 1000) carries geometry. A sticker
//  tapback (2007) and a sticker sent as its own message have the identity keys (`sid`, `pid`,
//  `shash`, `suri`) and none of these, so they have no placement, which is the truth: Messages
//  positions them itself. A row missing any one of the five is treated the same way, because
//  a sticker cannot be laid out from four of them.
//
//  The other keys are not decoded. They identify the sticker or describe how it was made
//  rather than where it goes, and none changes how the five are read.

import Foundation

public struct StoredStickerPlacement: Sendable, Equatable {
  public let xScalar: Double
  public let yScalar: Double
  public let scale: Double
  public let rotation: Double
  public let parentPreviewWidth: Double

  public init(
    xScalar: Double, yScalar: Double, scale: Double, rotation: Double, parentPreviewWidth: Double
  ) {
    self.xScalar = xScalar
    self.yScalar = yScalar
    self.scale = scale
    self.rotation = rotation
    self.parentPreviewWidth = parentPreviewWidth
  }

  /// The placement in a `sticker_user_info` blob, or nil when it has none.
  ///
  /// Nil for a blob that is not a dictionary plist as well as for one without the geometry:
  /// either way there is nothing to place, and the attachment is still served without it.
  /// The undecodable case is reported at `debug`, with no value from the blob.
  public init?(stickerUserInfo data: Data) {
    let decoded: Any
    do {
      decoded = try PropertyListSerialization.propertyList(from: data, format: nil)
    } catch {
      Rows.logger.debug("sticker_user_info is not a property list")
      return nil
    }
    guard let info = decoded as? [String: Any],
      let x = Self.number(info["sxs"]),
      let y = Self.number(info["sys"]),
      let scale = Self.number(info["ssa"]),
      let rotation = Self.number(info["sro"]),
      let width = Self.number(info["spw"])
    else { return nil }
    self.init(
      xScalar: x, yScalar: y, scale: scale, rotation: rotation, parentPreviewWidth: width)
  }

  /// A plist number or a decimal string, finite either way.
  private static func number(_ value: Any?) -> Double? {
    let parsed: Double?
    switch value {
    case let string as String: parsed = Double(string.trimmingCharacters(in: .whitespaces))
    case let number as NSNumber: parsed = number.doubleValue
    default: parsed = nil
    }
    return parsed.flatMap { $0.isFinite ? $0 : nil }
  }
}
