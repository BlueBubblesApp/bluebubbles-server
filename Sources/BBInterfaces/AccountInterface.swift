//  AccountInterface
//  The signed-in iMessage account: its details, its aliases, and the contact card it shares.
//
//  Every operation here is the helper's `AccountAccess` role and nothing else, so this
//  interface reads no database and is built per call over whichever helper is connected,
//  the shape `FindMyInterface` has. The wire shapes stay in `SystemHandlers` and
//  `MediaHandlers`: the reference fixes them, and fixing a shape is a projection, not a
//  meaning.

import BBPrivateAPIContract
import Foundation
import Logging

public struct AccountInterface: MessagesBackedInterface {

  /// The roles this interface calls, and no more.
  public typealias Helper = any AccountAccess

  let privateAPI: Helper?
  let logger: Logger

  public init(
    privateAPI: Helper?,
    logger: Logger = Logger(label: "bluebubbles.interface.account")
  ) {
    self.privateAPI = privateAPI
    self.logger = logger
  }

  // MARK: - The account

  public func info() async throws -> AccountInfo {
    let api = try requirePrivateAPI(for: "reading account information")
    return try await throughMessages { try await api.accountInfo() }
  }

  /// Makes `alias` the address this account sends from.
  ///
  /// Checked against the account's aliases first. IMCore accepts one it does not have and
  /// then silently keeps sending from the old one, which looks like the server ignored the
  /// request.
  ///
  /// Both lists, where the reference checks `vetted_aliases` alone
  /// (`iCloudInterface.modifyActiveAlias`). Deliberately the more permissive of the two:
  /// narrowing it would start refusing an alias that is accepted today, and a 400 a client
  /// used to get a 200 for is the break this project does not take.
  public func setActiveAlias(_ alias: String) async throws {
    let api = try requirePrivateAPI(for: "changing the active alias")
    let info = try await throughMessages { try await api.accountInfo() }
    let permitted = Set((info.aliases + info.vettedAliases).map(\.alias))
    guard permitted.contains(alias) else {
      throw InterfaceError.invalidRequest("`\(alias)` is not one of this account's aliases")
    }
    try await throughMessages { try await api.modifyActiveAlias(alias) }
  }

  // MARK: - The shared contact card

  /// The contact card `address` shared, or this account's own when it is nil.
  public func contactCard(for address: String?) async throws -> NicknameInfo {
    let api = try requirePrivateAPI(for: "reading a contact card")
    return try await throughMessages { try await api.nicknameInfo(for: address) }
  }

  /// Whether Messages would offer to share this account's card with a chat.
  public func shouldOfferContactSharing(chatGUID: String) async throws -> Bool {
    let api = try requirePrivateAPI(for: "contact sharing")
    return try await throughMessages {
      try await api.shouldOfferNicknameSharing(chat: ChatIdentifier(chatGUID))
    }
  }

  public func shareContact(chatGUID: String) async throws {
    let api = try requirePrivateAPI(for: "contact sharing")
    try await throughMessages { try await api.shareNickname(chat: ChatIdentifier(chatGUID)) }
  }
}
