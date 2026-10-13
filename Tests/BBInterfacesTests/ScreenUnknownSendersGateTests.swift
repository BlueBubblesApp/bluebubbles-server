//  ScreenUnknownSendersGateTests
//  Screening unknown senders is Tahoe and newer; the interface says so before the helper is
//  asked.
//
//  THE BUG THIS PINS is not that the gate was wrong. There was no gate. `-markAsKnownAndSave
//  InContacts:completion:` is absent below macOS 26, the helper's invoke threw, a `do/catch`
//  logged the throw and fell through to the state read, and `POST /chat/:guid/known` answered
//  **200 with the unchanged filter state** on Sonoma and Sequoia: the same response a client
//  gets when the call works and the flag does not move. `screenUnknownSenders.minimumMacOS`
//  was declared the whole time and nothing read it.

import BBPrivateAPICatalog
import Testing

@testable import BBInterfaces

@Suite("Screen unknown senders gate")
struct ScreenUnknownSendersGateTests {

  @Test("Sonoma and Sequoia are refused with the sentence, Tahoe passes")
  func gate() throws {
    for refused in [14, 15] {
      #expect(throws: InterfaceError.self) {
        try ChatInterface.checkScreenUnknownSendersSupported(majorVersion: refused)
      }
    }
    do {
      try ChatInterface.checkScreenUnknownSendersSupported(majorVersion: 14)
    } catch let error as InterfaceError {
      #expect("\(error)".contains("Screening unknown senders needs"))
      // The release is NAMED, not printed as a bare major: the sentence reaches a user.
      #expect("\(error)".contains("Tahoe"))
    }
    try ChatInterface.checkScreenUnknownSendersSupported(majorVersion: 26)
  }

  /// The floor is the catalog's, not a literal, so a corrected catalog corrects the gate.
  /// `CapabilityCatalogTests` checks that floor against `docs/headers/`, which is what makes
  /// this a measurement rather than two constants that happen to agree today.
  @Test("The gate reads its floor from the capability, not from a version literal")
  func floorComesFromTheCatalog() throws {
    try ChatInterface.checkScreenUnknownSendersSupported(
      majorVersion: PrivateAPICapability.screenUnknownSenders.minimumMacOS)
    #expect(throws: InterfaceError.self) {
      try ChatInterface.checkScreenUnknownSendersSupported(
        majorVersion: PrivateAPICapability.screenUnknownSenders.minimumMacOS - 1)
    }
  }
}
