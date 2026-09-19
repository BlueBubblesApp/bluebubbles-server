//  BBPrivateAPIContract: Account
//  The sending account: its addresses, its display name and its nickname.
//
//  These shapes are transcribed from what the Objective-C helper sent rather than from what
//  IMCore exposes, because a client reads them positionally and a thinner payload is a crash
//  rather than a smaller response. Each type's header says which recorded fixture pins it.

import Foundation

/// One address the account can send from, as the wire carries it.
///
/// **An OBJECT, not a string, and the capitalised keys are the contract.** IMCore's
/// `aliases` and `vettedAliases` are arrays of plain strings; the ObjC helper enriched each
/// one through `[account _aliasInfoForAlias:]` before sending it, and the recorded
/// `get_api_v1_icloud_account-5baa61-200.json` shows the result: `{"Alias", "Status",
/// "IsUserVisible"}`. The app reads `e['Alias']` off every element
/// (`profile_panel.dart:401`), so a bare string there is not a thinner payload — it is a
/// crash, `type 'String' is not a subtype of type 'int' of 'index'`, because Dart's
/// `String.[]` takes an integer.
///
/// `status` and `isUserVisible` are optional because the helper's own fallback omits them:
/// when `_aliasInfoForAlias:` answers nil it sends `{"Alias": <the string>}` alone.
public struct AccountAlias: Codable, Sendable, Equatable {
  public let alias: String
  public let status: Int?
  public let isUserVisible: Bool?

  public init(alias: String, status: Int? = nil, isUserVisible: Bool? = nil) {
    self.alias = alias
    self.status = status
    self.isUserVisible = isUserVisible
  }
}

public struct AccountInfo: Codable, Sendable {
  public let appleId: String?
  /// The person's name, from `[[account loginIMHandle] fullName]`. Not the Apple ID.
  public let accountName: String?
  public let activeAlias: String?
  public let aliases: [AccountAlias]
  public let vettedAliases: [AccountAlias]
  /// `[account loginStatusMessage]` — "Connected" and friends. The app renders it verbatim
  /// and compares it to `"Connected"` to colour its indicator.
  public let loginStatusMessage: String?
  /// Both read from the SMS account rather than the iMessage one, which is a separate
  /// `IMAccount`: `activeSMSAccount`, not `activeIMessageAccount`.
  public let smsForwardingEnabled: Bool
  public let smsForwardingCapable: Bool

  public init(
    appleId: String?,
    accountName: String? = nil,
    activeAlias: String?,
    aliases: [AccountAlias],
    vettedAliases: [AccountAlias],
    loginStatusMessage: String? = nil,
    smsForwardingEnabled: Bool = false,
    smsForwardingCapable: Bool = false
  ) {
    self.appleId = appleId
    self.accountName = accountName
    self.activeAlias = activeAlias
    self.aliases = aliases
    self.vettedAliases = vettedAliases
    self.loginStatusMessage = loginStatusMessage
    self.smsForwardingEnabled = smsForwardingEnabled
    self.smsForwardingCapable = smsForwardingCapable
  }
}

/// A shared contact card: the name and photo someone chose to share, which is distinct
/// from anything in Contacts.
///
/// `handle` is nil for the LOCAL user's own card, which is what `icloud.contactCard`
/// returns when no address is given. That case is not a degenerate one: it is the request
/// the reference server's fixture records.
public struct NicknameInfo: Codable, Sendable {
  public let handle: String?
  public let name: String?
  public let hasSharedNickname: Bool
  /// Where Messages keeps the shared photo, or nil when there is none.
  ///
  /// A PATH rather than the bytes, matching the reference implementation: the file lives on
  /// the same Mac, the server already requires Full Disk Access, and an avatar is large
  /// enough that routing it through the helper socket would be paid on every call. The
  /// server reads it and base64-encodes it; see `SystemHandlers`.
  public let avatarPath: String?

  public init(
    handle: String?, name: String?, hasSharedNickname: Bool, avatarPath: String? = nil
  ) {
    self.handle = handle
    self.name = name
    self.hasSharedNickname = hasSharedNickname
    self.avatarPath = avatarPath
  }
}
