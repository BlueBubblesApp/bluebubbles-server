//  SendLaterGuidanceTests
//  The notice on the Scheduled Messages page says the right thing for this Mac.
//
//  Three states, and they are different advice rather than three phrasings: a Mac that
//  cannot run Send Later at all, one that could with the Private API on, and one where it
//  should be the first choice. The version floor is the catalog's, not a number typed here.

import BBPrivateAPICatalog
import Testing

@testable import BlueBubblesApp

@Suite("Send Later guidance")
struct SendLaterGuidanceTests {

  @Test("The version floor is the catalog's, not a copy")
  func floorComesFromTheCatalog() {
    #expect(SendLaterGuidance.minimumMacOS == PrivateAPICapability.sendLater.minimumMacOS)
  }

  @Test("A Mac below the floor is told scheduling here is the right tool")
  func olderMacIsUnavailable() {
    let floor = SendLaterGuidance.minimumMacOS
    for presence in [PrivateAPIPresence.notEnabled, .enabledButNotWorking, .connected] {
      let guidance = SendLaterGuidance(macOSMajor: floor - 1, privateAPI: presence)
      #expect(guidance == .unavailable(macOSMajor: floor - 1))
      // Named both ways: the release it needs, and the one this Mac has.
      let text = guidance.messages.joined(separator: " ")
      #expect(text.contains(PrivateAPICapability.releaseName(floor)))
      #expect(text.contains(PrivateAPICapability.releaseName(floor - 1)))
      // Nothing to set up: the Private API would not bring Send Later to this Mac.
      #expect(!guidance.offersPrivateAPISetup)
    }
  }

  @Test("At the floor with the Private API off, it names the prerequisite and offers it")
  func needsPrivateAPI() {
    let guidance = SendLaterGuidance(
      macOSMajor: SendLaterGuidance.minimumMacOS, privateAPI: .notEnabled)
    #expect(guidance == .needsPrivateAPI)
    #expect(guidance.offersPrivateAPISetup)
    #expect(guidance.messages.contains { $0.contains("Private API") })
  }

  @Test("With the Private API on, Send Later is recommended and recurrence is called out")
  func recommended() {
    for presence in [PrivateAPIPresence.enabledButNotWorking, .connected] {
      let guidance = SendLaterGuidance(
        macOSMajor: SendLaterGuidance.minimumMacOS + 11, privateAPI: presence)
      #expect(guidance == .recommended)
      #expect(!guidance.offersPrivateAPISetup)
      // The one reason to stay on this page when Send Later is available.
      #expect(guidance.messages.contains { $0.contains("recurring") })
    }
  }
}
