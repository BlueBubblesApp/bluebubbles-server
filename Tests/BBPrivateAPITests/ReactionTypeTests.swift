//  ReactionTypeTests
//  The wire names and IMCore numbers for tapbacks, including the emoji pair.

import BBPrivateAPIContract
import Testing

@Suite("Reaction types")
struct ReactionTypeTests {

  @Test("Emoji tapbacks are 2006 and 3006, spelled emoji and -emoji")
  func emojiTypes() {
    #expect(ReactionType(rawValue: "emoji")?.associatedMessageType == 2006)
    #expect(ReactionType(rawValue: "-emoji")?.associatedMessageType == 3006)
    #expect(ReactionType.emoji.isEmoji)
    #expect(ReactionType.removeEmoji.isEmoji)
    #expect(ReactionType.removeEmoji.isRemoval)
    #expect(!ReactionType.emoji.isRemoval)
    #expect(!ReactionType.love.isEmoji)
  }

  @Test("Removal is always the add plus 1000, for every pair")
  func removalOffsets() {
    for reaction in ReactionType.allCases where !reaction.isRemoval {
      let removal = ReactionType(rawValue: "-" + reaction.rawValue)
      #expect(removal?.associatedMessageType == reaction.associatedMessageType + 1000)
    }
  }

  @Test("The request carries the emoji only for the emoji types")
  func requestEmoji() {
    let request = ReactionRequest(
      chat: ChatIdentifier("c"), target: MessageGUID("m"), reaction: .emoji, emoji: "🔥")
    #expect(request.emoji == "🔥")
    #expect(
      ReactionRequest(chat: ChatIdentifier("c"), target: MessageGUID("m"), reaction: .love).emoji
        == nil)
  }
}
