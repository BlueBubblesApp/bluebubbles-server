//  ChatBackgroundGateTests
//  Conversation backgrounds are Tahoe and newer; the interface says so before the helper is
//  asked.
//
//  UNLIKE `ScreenUnknownSendersGateTests`, the bug here was lateness, not wrongness. The
//  helper already refused below 26: `-refetchLocalTranscriptBackgroundAssetIfNecessary` is
//  absent, the invoke threw, and `translating` turned that into `unavailableOnThisOS`. What
//  the gate changes is WHERE the refusal happens, and that it names macOS Tahoe rather than
//  a private selector the person reading it cannot act on.
//
//  The reads stay ungated on purpose, and that is the part worth pinning: `GET
//  :guid/background` serves bytes already cached on disk, and a release with no backgrounds
//  answering "no background" is a correct answer, not an error.

import BBPrivateAPICatalog
import Testing

@testable import BBInterfaces

@Suite("Chat background gate")
struct ChatBackgroundGateTests {

  @Test("Sonoma and Sequoia are refused with the sentence, Tahoe passes")
  func gate() throws {
    for refused in [14, 15] {
      #expect(throws: InterfaceError.self) {
        try ChatInterface.checkChatBackgroundsSupported(majorVersion: refused)
      }
    }
    do {
      try ChatInterface.checkChatBackgroundsSupported(majorVersion: 15)
    } catch let error as InterfaceError {
      #expect("\(error)".contains("Conversation backgrounds need"))
      // Names the RELEASE, not the selector: the sentence reaches a user.
      #expect("\(error)".contains("Tahoe"))
      #expect(!"\(error)".contains("refetchLocalTranscriptBackgroundAssetIfNecessary"))
    }
    try ChatInterface.checkChatBackgroundsSupported(majorVersion: 26)
  }

  /// The floor is the catalog's, not a literal, so a corrected catalog corrects the gate.
  /// `CapabilityCatalogTests` checks that floor against `docs/headers/`.
  @Test("The gate reads its floor from the capability, not from a version literal")
  func floorComesFromTheCatalog() throws {
    try ChatInterface.checkChatBackgroundsSupported(
      majorVersion: PrivateAPICapability.chatBackgrounds.minimumMacOS)
    #expect(throws: InterfaceError.self) {
      try ChatInterface.checkChatBackgroundsSupported(
        majorVersion: PrivateAPICapability.chatBackgrounds.minimumMacOS - 1)
    }
  }

  /// Both 26-only chat capabilities now refuse at the same layer, which is the symmetry the
  /// audit was after: neither reaches the helper on a release that cannot serve it.
  @Test("Both 26-only chat capabilities gate at the interface")
  func symmetry() throws {
    for majorVersion in [14, 15] {
      #expect(throws: InterfaceError.self) {
        try ChatInterface.checkChatBackgroundsSupported(majorVersion: majorVersion)
      }
      #expect(throws: InterfaceError.self) {
        try ChatInterface.checkScreenUnknownSendersSupported(majorVersion: majorVersion)
      }
    }
    try ChatInterface.checkChatBackgroundsSupported(majorVersion: 26)
    try ChatInterface.checkScreenUnknownSendersSupported(majorVersion: 26)
  }
}
