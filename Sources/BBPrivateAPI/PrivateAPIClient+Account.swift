//  PrivateAPIClient+Account
//  The small roles that ask Messages about one thing: an address (`HandleAvailability`),
//  the signed-in account and its nickname (`AccountAccess`), or one purged attachment
//  (`AttachmentAccess`).
//
//  One slice of `PrivateAPIClient`; the type, its transport and the payload shapes every
//  role shares are in `PrivateAPIClient.swift`.

import BBPrivateAPIContract
import Foundation

extension PrivateAPIClient: HandleAvailability {

  public func checkIMessageAvailability(address: String) async throws -> Bool {
    try await availability(.checkIMessageAvailability, address: address)
  }

  public func checkFaceTimeAvailability(address: String) async throws -> Bool {
    try await availability(.checkFaceTimeAvailability, address: address)
  }

  public func checkFocusStatus(address: String) async throws -> String {
    let result = try await transport.request(
      action: .checkFocusStatus,
      data: .object([.address: .string(address)])
    )
    return try WireReader(reply: result, to: .checkFocusStatus).string(.status)
  }

  private func availability(
    _ action: MessagesHelperAction, address: String
  ) async throws -> Bool {
    let result = try await transport.request(
      action: action, data: .object([.address: .string(address)])
    )
    return try WireReader(reply: result, to: action).bool(.available)
  }
}

extension PrivateAPIClient: AccountAccess {

  public func accountInfo() async throws -> AccountInfo {
    let result = try await transport.request(
      action: .getAccountInfo, data: .emptyObject)

    /// An alias object, tolerating the bare string an older helper sends.
    ///
    /// The helper and the server ship together, so the string form is not a case this has
    /// to serve forever — but a helper is injected into a running Messages and survives a
    /// server restart, so the two versions DO meet in practice. Reading a string as
    /// `{alias}` keeps that pairing working instead of emptying the list.
    func alias(_ value: WireJSON) -> AccountAlias? {
      if let flat = value.stringValue { return AccountAlias(alias: flat) }
      guard let name = value[WireKey.aliasName]?.stringValue else { return nil }
      return AccountAlias(
        alias: name,
        status: value[WireKey.aliasStatus]?.intValue,
        isUserVisible: value[WireKey.aliasIsUserVisible]?.boolValue
      )
    }

    return AccountInfo(
      appleId: result?[.appleId]?.stringValue,
      accountName: result?[.accountName]?.stringValue,
      activeAlias: result?[.activeAlias]?.stringValue,
      aliases: result?[.aliases]?.arrayValue?.compactMap(alias) ?? [],
      vettedAliases: result?[.vettedAliases]?.arrayValue?.compactMap(alias) ?? [],
      loginStatusMessage: result?[.loginStatusMessage]?.stringValue,
      smsForwardingEnabled: result?[.smsForwardingEnabled]?.boolValue ?? false,
      smsForwardingCapable: result?[.smsForwardingCapable]?.boolValue ?? false
    )
  }

  public func nicknameInfo(for address: String?) async throws -> NicknameInfo {
    // The key is OMITTED rather than sent as null when there is no address: the helper
    // reads it with `optionalString`, and an explicit null would be indistinguishable from
    // a caller that meant to send one.
    let result = try await transport.request(
      action: .getNicknameInfo,
      data: .object(dropping: [.address: address.map(WireJSON.string)])
    )
    return NicknameInfo(
      handle: address ?? result?[.handle]?.stringValue,
      name: result?[.name]?.stringValue,
      hasSharedNickname: result?[.hasSharedNickname]?.boolValue ?? false,
      avatarPath: result?[.avatarPath]?.stringValue
    )
  }

  public func shouldOfferNicknameSharing(chat: ChatIdentifier) async throws -> Bool {
    let result = try await transport.request(
      action: .shouldOfferNicknameSharing,
      data: .object([.chatGuid: .string(chat.rawValue)])
    )
    return try WireReader(reply: result, to: .shouldOfferNicknameSharing).bool(.shouldOffer)
  }

  public func shareNickname(chat: ChatIdentifier) async throws {
    try await chatAction(.shareNickname, chat)
  }

  public func modifyActiveAlias(_ alias: String) async throws {
    try await transport.request(
      action: .modifyActiveAlias,
      data: .object([
        .alias: .string(alias)
      ]))
  }
}

extension PrivateAPIClient: AttachmentAccess {

  public func downloadPurgedAttachment(guid: String) async throws -> String {
    let result = try await transport.request(
      action: .downloadPurgedAttachment,
      data: .object([.attachmentGuid: .string(guid)])
    )
    return try WireReader(reply: result, to: .downloadPurgedAttachment).string(.path)
  }
}
