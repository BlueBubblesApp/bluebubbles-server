//  StickerPlacementTests
//  A placed sticker's position, from `sticker_user_info` to the attachment's `stickerPlacement`.
//
//  The blob's numbers are decimal strings on most rows and plist reals on a few, so both
//  shapes are built here. A sticker tapback carries only identity keys, and the attachment is
//  served without a placement rather than with a made-up one.

import BBCore
import BBIMessage
import Foundation
import Testing

@testable import BBSerialization

@Suite("Sticker placement")
struct StickerPlacementTests {

  private func plist(_ info: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
  }

  private func serialized(
    _ info: Data?, isForNotification: Bool = false
  ) throws -> JSONValue {
    let row = try Rows.attachment(isSticker: true, stickerUserInfo: info)
    return AttachmentSerializer.serialize(
      row, hasLivePhoto: false, isForNotification: isForNotification)
  }

  @Test("decimal strings, as Messages stores most rows")
  func strings() throws {
    let info = try plist([
      "sxs": "0.11932647", "sys": "0.87515042", "ssa": "1.0456733", "sro": "-0.10534884",
      "spw": "265", "sai": "0", "sli": "0", "sid": "0000-sticker", "shash": "0000",
    ])
    let placement = try #require(try serialized(info)["stickerPlacement"])
    #expect(
      placement
        == .object([
          "xScalar": .double(0.11932647), "yScalar": .double(0.87515042),
          "scale": .double(1.0456733), "rotation": .double(-0.10534884),
          "parentPreviewWidth": .double(265),
        ]))
  }

  @Test("plist reals, as a few rows store them")
  func reals() throws {
    let info = try plist([
      "sxs": 0.5255, "sys": 0.5557, "ssa": 0.35, "sro": 0.0, "spw": 195.62, "spv": 1,
      "sir": false,
    ])
    let placement = try #require(try serialized(info)["stickerPlacement"])
    #expect(placement["xScalar"] == .double(0.5255))
    #expect(placement["rotation"] == .double(0))
    #expect(placement["parentPreviewWidth"] == .double(195.62))
  }

  @Test("absent when the blob has no geometry, is partial, or is not a plist")
  func absent() throws {
    // A sticker tapback: identity keys only.
    let tapback = try plist(["sid": "0000-sticker", "pid": "pack", "shash": "0000", "suri": ""])
    // Four of the five: not enough to lay a sticker out.
    let partial = try plist(["sxs": "0.5", "sys": "0.5", "ssa": "0.35", "sro": "0"])
    let notNumbers = try plist([
      "sxs": "left", "sys": "0.5", "ssa": "0.35", "sro": "0", "spw": "200",
    ])
    for info in [nil, tapback, partial, notNumbers, Data("not a plist".utf8)] {
      let object = try serialized(info)
      #expect(object["stickerPlacement"] == nil)
      #expect(object["isSticker"] == .bool(true))
    }
  }

  @Test("not on a notification payload")
  func notification() throws {
    let info = try plist(["sxs": "0.5", "sys": "0.5", "ssa": "0.35", "sro": "0", "spw": "200"])
    #expect(try serialized(info)["stickerPlacement"] != nil)
    #expect(try serialized(info, isForNotification: true)["stickerPlacement"] == nil)
  }
}
