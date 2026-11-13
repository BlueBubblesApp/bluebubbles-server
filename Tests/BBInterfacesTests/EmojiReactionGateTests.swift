//  EmojiReactionGateTests
//  Emoji reactions are Sequoia and newer; the interface says so before the helper is asked.

import Testing

@testable import BBInterfaces

@Suite("Emoji reaction gate")
struct EmojiReactionGateTests {

  @Test("Sonoma is refused with the sentence, Sequoia and Tahoe pass")
  func gate() throws {
    #expect(throws: InterfaceError.self) {
      try MessageInterface.checkEmojiReactionSupported(majorVersion: 14)
    }
    do {
      try MessageInterface.checkEmojiReactionSupported(majorVersion: 14)
    } catch let error as InterfaceError {
      #expect(
        "\(error)".contains("Emoji reactions are only supported on macOS Sequoia (15) and newer"))
    }
    try MessageInterface.checkEmojiReactionSupported(majorVersion: 15)
    try MessageInterface.checkEmojiReactionSupported(majorVersion: 26)
  }
}
