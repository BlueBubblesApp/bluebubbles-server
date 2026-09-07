//  ContactCardWireShapeTests
//  `GET /api/v1/icloud/contact` — the two-key shape, and why v2 exists beside it.
//
//  The helper reports more than v1 may return. `NicknameInfo` carries the handle, whether a
//  card was shared at all, and the avatar path; the reference server's response carries
//  exactly `name` and `avatar`. An extra key fails the parity diff the same way a missing
//  one does, so the narrowing is asserted rather than left to the handler's shape.
//
//  Reference: packages/server/src/server/api/interfaces/iCloudInterface.ts:17-31,
//  and Fixtures/http/get_api_v1_icloud_contact-5baa61-200.json.

import BBHTTPAPI
import BBPrivateAPIContract
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers
@testable import BlueBubblesServerCore

@Suite("Contact card wire shape")
struct ContactCardWireShapeTests {

  /// The avatar is read from disk by the SERVER, matching the reference, so a test needs a
  /// real file for the key to appear.
  private func temporaryAvatar(_ bytes: [UInt8] = [0xFF, 0xD8, 0xFF]) throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-avatar-\(UUID().uuidString).jpg")
    try Data(bytes).write(to: url)
    return url.path
  }

  @Test("v1 returns name and avatar, and nothing else")
  func v1KeySet() throws {
    let path = try temporaryAvatar()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let card = NicknameInfo(
      handle: "someone@example.com", name: "Example Person",
      hasSharedNickname: true, avatarPath: path
    )
    let data = SystemHandlers.contactCardPayload(card, includingExtendedKeys: false)
    #expect(Set(data.keys) == ["name", "avatar"])
    #expect(data["name"]?.stringValue == "Example Person")
    #expect(data["avatar"]?.stringValue == Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
  }

  /// The reference only adds `avatar` when the helper reported a path, so a card without a
  /// photo has one key. It does NOT emit `avatar: null`.
  @Test("v1 omits avatar entirely when there is no photo")
  func v1OmitsAbsentAvatar() {
    let card = NicknameInfo(
      handle: "someone@example.com", name: "Example Person",
      hasSharedNickname: true, avatarPath: nil
    )
    let data = SystemHandlers.contactCardPayload(card, includingExtendedKeys: false)
    #expect(Set(data.keys) == ["name"])
  }

  /// A path the helper reported but the server cannot read omits the key rather than
  /// failing the request: the name is still worth returning.
  @Test("An unreadable avatar path omits the key rather than failing")
  func v1UnreadableAvatar() {
    let card = NicknameInfo(
      handle: nil, name: "Example Person", hasSharedNickname: true,
      avatarPath: "/nonexistent/\(UUID().uuidString).jpg"
    )
    let data = SystemHandlers.contactCardPayload(card, includingExtendedKeys: false)
    #expect(Set(data.keys) == ["name"])
  }

  /// Nobody has shared anything: v1 can only say so by returning an empty object, which is
  /// exactly what makes the v2 shape worth having.
  @Test("v1 collapses no-card and empty-card to the same empty object")
  func v1CannotDistinguishAbsence() {
    let absent = NicknameInfo(handle: "x@example.com", name: nil, hasSharedNickname: false)
    let empty = NicknameInfo(handle: "x@example.com", name: nil, hasSharedNickname: true)
    #expect(SystemHandlers.contactCardPayload(absent, includingExtendedKeys: false).isEmpty)
    #expect(SystemHandlers.contactCardPayload(empty, includingExtendedKeys: false).isEmpty)
  }

  @Test("v2 carries the handle and the shared flag that v1 cannot")
  func v2KeySet() {
    let absent = NicknameInfo(handle: "x@example.com", name: nil, hasSharedNickname: false)
    let empty = NicknameInfo(handle: "x@example.com", name: nil, hasSharedNickname: true)

    let absentData = SystemHandlers.contactCardPayload(absent, includingExtendedKeys: true)
    let emptyData = SystemHandlers.contactCardPayload(empty, includingExtendedKeys: true)
    #expect(Set(absentData.keys) == ["handle", "name", "has_shared_nickname", "avatar"])
    // The distinction v1 loses.
    #expect(absentData["has_shared_nickname"]?.boolValue == false)
    #expect(emptyData["has_shared_nickname"]?.boolValue == true)
  }
}
