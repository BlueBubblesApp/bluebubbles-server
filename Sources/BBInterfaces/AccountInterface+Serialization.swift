//  AccountInterface+Serialization
//  The account and contact-card routes' wire shapes.
//
//  Here rather than in the handlers so the app and the tests reach the projection the routes
//  send, and so a handler stays parse, call, serialize. Both v1 shapes are FROZEN and diffed
//  against recorded fixtures; see each function.

import BBCore
import BBPrivateAPIContract
import Foundation

extension AccountInterface {

  /// The contact card on the wire, for both versions.
  ///
  /// Shared so the avatar is read one way. The **v1 shape is frozen** at the reference's two
  /// keys; see `ContactCardWireShapeTests` and
  /// `Fixtures/http/get_api_v1_icloud_contact-5baa61-200.json`, and the differences are not
  /// cosmetic:
  ///
  /// - v1 OMITS a key it has no value for; v2 emits `null`. The reference builds its object
  ///   by assignment and deletes `avatar_path`, so a card with no photo simply has no
  ///   `avatar` key, and a client checking `"avatar" in data` would break if one appeared.
  /// - v1 cannot say whether a card was shared at all. A person who shared nothing and a
  ///   person who shared an empty card both reduce to `{}`. That is what `v2` adds.
  ///
  /// The avatar is read HERE, by the server, rather than in the helper: the helper reports a path, the
  /// server reads the bytes. Keeping file I/O out of code injected into Messages.app is the
  /// reason: the helper runs inside someone else's sandboxed process and every byte it reads
  /// is a byte read under that process's rules. An unreadable path omits the key rather
  /// than failing the request: the name is still worth returning, and a photo can be
  /// referenced before it has been downloaded.
  public static func contactCardPayload(
    _ card: NicknameInfo, includingExtendedKeys extended: Bool
  ) -> [String: JSONValue] {
    var avatar: JSONValue?
    if let path = card.avatarPath, let bytes = FileManager.default.contents(atPath: path) {
      avatar = .string(bytes.base64EncodedString())
    }

    guard extended else {
      var data: [String: JSONValue] = [:]
      if let name = card.name { data["name"] = .string(name) }
      if let avatar { data["avatar"] = avatar }
      return data
    }

    return [
      "handle": card.handle.map(JSONValue.string) ?? .null,
      "name": card.name.map(JSONValue.string) ?? .null,
      "has_shared_nickname": .bool(card.hasSharedNickname),
      "avatar": avatar ?? .null,
    ]
  }

  /// `GET /api/v1/icloud/account`'s `data`, as the reference sends it.
  ///
  /// A static beside `contactCardPayload` for the same reason: the shape is the contract and
  /// a test has to be able to reach it without a helper. `AccountWireShapeTests` diffs it
  /// against `Fixtures/http/get_api_v1_icloud_account-5baa61-200.json`.
  public static func accountInfoPayload(_ info: AccountInfo) -> [String: JSONValue] {
    func aliases(_ values: [AccountAlias]) -> JSONValue {
      .array(
        values.map { alias in
          var object: [String: JSONValue] = ["Alias": .string(alias.alias)]
          // Omitted rather than nulled when IMCore did not describe the alias, which is
          // what the helper's own `{"Alias": …}` fallback produces.
          if let status = alias.status { object["Status"] = .int(status) }
          if let visible = alias.isUserVisible { object["IsUserVisible"] = .bool(visible) }
          return .object(object)
        })
    }

    return [
      "apple_id": info.appleId.map(JSONValue.string) ?? .null,
      "account_name": info.accountName.map(JSONValue.string) ?? .null,
      "active_alias": info.activeAlias.map(JSONValue.string) ?? .null,
      "aliases": aliases(info.aliases),
      "vetted_aliases": aliases(info.vettedAliases),
      "login_status_message": info.loginStatusMessage.map(JSONValue.string) ?? .null,
      "sms_forwarding_enabled": .bool(info.smsForwardingEnabled),
      "sms_forwarding_capable": .bool(info.smsForwardingCapable),
    ]
  }
}
