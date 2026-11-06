//  DeviceRowSummaryTests
//  What a registered-devices row says about a push registration.
//
//  Three decisions, and each one has a wrong answer that looks right on screen.
//  "Never connected" rather than a formatted epoch zero, which is what a nil-coalescing
//  default would have produced. "legacy-v1" rather than a blank tag, because a null codec
//  column is the DEFAULT and not a missing value. And an abbreviated push token rather than
//  the whole one, which is both unreadable and the delivery address for somebody's phone.
//
//  Takes values rather than records, so none of this needs a database row built to assert.
//
//  NO REAL ADDRESSES OR TOKENS; see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Device row summary")
struct DeviceRowSummaryTests {

  // MARK: - Last seen

  @Test("A device that has never connected says so, rather than showing the epoch")
  func neverConnected() {
    #expect(DeviceRowSummary.hasNeverConnected(nil))
    #expect(DeviceRowSummary.lastSeen(nil) == "Never connected")
    // The failure this guards: a `?? Date(timeIntervalSince1970: 0)` default.
    #expect(!DeviceRowSummary.lastSeen(nil).contains("1970"))
  }

  @Test("A device that has connected is described relative to now")
  func hasConnected() {
    let seen = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(!DeviceRowSummary.hasNeverConnected(seen))
    #expect(DeviceRowSummary.lastSeen(seen).hasPrefix("Last seen "))
  }

  // MARK: - Codec

  /// The column is null until a client advertises something and the negotiator's floor is
  /// legacy-v1, so "no codecs" is a device ON legacy-v1, not a device with no answer.
  @Test("A device advertising nothing is on legacy-v1, not blank")
  func codecDefaults() {
    #expect(DeviceRowSummary.codec(nil) == "legacy-v1")
    #expect(DeviceRowSummary.codec("") == "legacy-v1")
    // A column that is present but holds only separators is the same nothing. Written by
    // hand or left by a half-finished negotiation, it must not render as an empty tag.
    #expect(DeviceRowSummary.codec(" , ") == "legacy-v1")
  }

  @Test("A device that advertised codecs shows the first one")
  func codecAdvertised() {
    #expect(DeviceRowSummary.codec("sealed-v2") == "sealed-v2")
    #expect(DeviceRowSummary.codec("sealed-v2,legacy-v1") == "sealed-v2")
    // Stored with spaces by a writer that formatted the list for a human.
    #expect(DeviceRowSummary.codec(" sealed-v2 , legacy-v1 ") == "sealed-v2")
  }

  // MARK: - Token

  /// A registration token is the address notifications are delivered to. It is why
  /// `LogRedactionPolicyTests` keeps one out of a log line, and a screenshot of this page
  /// in a support thread is the same exposure by a slower route.
  @Test("A long token is shown abbreviated, never whole")
  func tokenIsAbbreviated() {
    let token = String(repeating: "a", count: 40) + "TAILXX"
    let shown = DeviceRowSummary.shortToken(token)
    #expect(shown != token)
    #expect(!shown.contains(String(repeating: "a", count: 20)))
    #expect(shown.hasSuffix("TAILXX"))
    #expect(shown.contains("…"))
  }

  /// Enough of both ends to tell two phones apart and to match a row against the Firebase
  /// console. A one-ended elision would make every token from one client look identical.
  @Test("Both ends survive, so two devices can be told apart")
  func bothEndsSurvive() {
    let first = "HEADAAmiddlemiddlemiddlemiddleZZTAIL1"
    let second = "HEADAAmiddlemiddlemiddlemiddleZZTAIL2"
    #expect(DeviceRowSummary.shortToken(first).hasPrefix("HEADAA"))
    #expect(DeviceRowSummary.shortToken(first) != DeviceRowSummary.shortToken(second))
  }

  /// An elision that hides nothing is a lie about what is on screen: it tells the reader
  /// there is more token than they can see when there is not.
  @Test("A token too short to abbreviate is shown as it is")
  func shortTokenIsUntouched() {
    #expect(DeviceRowSummary.shortToken("abc") == "abc")
    // The boundary, both sides of it. Keeping six from each end of THIRTEEN characters
    // hides exactly one and spends a character saying so: the same length on screen, one
    // character less of the token, and a reader told there is more than there is. At
    // fourteen it starts being worth it.
    #expect(DeviceRowSummary.shortToken("abcdefghijklm") == "abcdefghijklm")
    #expect(DeviceRowSummary.shortToken("abcdefghijklmn") == "abcdef…ijklmn")
  }
}
