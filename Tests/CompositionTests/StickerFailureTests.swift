//  StickerFailureTests
//  What a client receives when Messages refuses to add a sticker to the store.
//
//  Same contract as its siblings: a refusal from Messages is `InterfaceError.messagesFailed`,
//  projecting to the 500 `iMessage Error`, never a generic server error.
//
//  The file is real for the same reason it is in `SendFailureTests`' sticker row: the save
//  stages it into Messages' container before the helper is asked, and a missing file would
//  fail there and assert a translation the helper never produced.

import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Sticker failure translation")
struct StickerFailureTests {

  /// Every sticker operation that reaches Messages, by name.
  private func operations(
    _ stickers: StickerInterface, filePath: String
  ) -> [(String, () async throws -> Void)] {
    [
      (
        "save",
        { _ = try await stickers.save(filePath: filePath, name: nil, accessibilityName: nil) }
      )
    ]
  }

  @Test("Every sticker operation reports a helper refusal as an iMessage error")
  func everyOperationTranslates() async throws {
    let stickers = StickerInterface(privateAPI: FailingPrivateAPI())
    let filePath = try InterfaceFixtures.temporaryFile()

    for (name, operation) in operations(stickers, filePath: filePath) {
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

  @Test("With no helper, saving a sticker is the gate's refusal")
  func missingHelperIsTheGate() async throws {
    let stickers = StickerInterface(privateAPI: nil)

    let error = await #expect(throws: InterfaceError.self) {
      _ = try await stickers.save(filePath: "/unused", name: nil, accessibilityName: nil)
    }
    #expect(error == .helperUnavailable(feature: "saving a sticker"))
  }
}
