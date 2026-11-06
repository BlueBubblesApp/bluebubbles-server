//  AccountFailureTests
//  What a client receives when Messages refuses an account or contact-card operation.
//
//  Same contract as its siblings: a refusal from Messages is `InterfaceError.messagesFailed`,
//  projecting to the 500 `iMessage Error`, never a generic server error. These were one-line
//  helper calls made from `SystemHandlers` and `MediaHandlers`, outside `throughMessages`,
//  until `AccountInterface` held them.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPrivateAPIContract
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Account failure translation")
struct AccountFailureTests {

  private static let chat = "iMessage;-;person@example.com"
  private static let alias = "person@example.com"

  /// Every account operation that reaches Messages, by name, so a failure says which one.
  private func operations(
    _ account: AccountInterface
  ) -> [(String, () async throws -> Void)] {
    [
      ("info", { _ = try await account.info() }),
      ("setActiveAlias", { try await account.setActiveAlias(Self.alias) }),
      ("contactCard", { _ = try await account.contactCard(for: nil) }),
      (
        "shouldOfferContactSharing",
        { _ = try await account.shouldOfferContactSharing(chatGUID: Self.chat) }
      ),
      ("shareContact", { try await account.shareContact(chatGUID: Self.chat) }),
    ]
  }

  @Test("Every account operation reports a helper refusal as an iMessage error")
  func everyOperationTranslates() async throws {
    let account = AccountInterface(privateAPI: FailingPrivateAPI())

    for (name, operation) in operations(account) {
      do {
        try await operation()
        Issue.record("\(name) should have failed")
      } catch let error as InterfaceError {
        #expect(error == .messagesFailed("Messages said no"), "\(name)")
      } catch {
        Issue.record("\(name) threw \(type(of: error)) rather than InterfaceError: \(error)")
      }
    }
  }

  @Test("With no helper, every account operation is the gate's refusal")
  func missingHelperIsTheGate() async throws {
    let account = AccountInterface(privateAPI: nil)

    for (name, operation) in operations(account) {
      do {
        try await operation()
        Issue.record("\(name) should have been refused")
      } catch let error as InterfaceError {
        guard case .helperUnavailable = error else {
          Issue.record("\(name): expected .helperUnavailable, got \(error)")
          continue
        }
      }
    }
  }

  @Test("An alias the account does not have is the caller's mistake, refused before IMCore")
  func unknownAliasIsRefused() async throws {
    // IMCore accepts an alias it does not have and keeps sending from the old one, so this
    // check is the only thing between the client and a request that silently does nothing.
    var helper = FailingPrivateAPI()
    helper.onAccountInfo = {
      AccountInfo(appleId: nil, activeAlias: nil, aliases: [], vettedAliases: [])
    }
    let account = AccountInterface(privateAPI: helper)

    let error = await #expect(throws: InterfaceError.self) {
      try await account.setActiveAlias(Self.alias)
    }
    #expect(error == .invalidRequest("`\(Self.alias)` is not one of this account's aliases"))
  }
}
