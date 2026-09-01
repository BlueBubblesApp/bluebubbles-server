//  AddressFormatterTests
//  The address half of a chat GUID, which decides whether a send lands at all.
//
//  `AddressFormatter`'s own header explains the stakes: a chat GUID is `service;-;address`,
//  and the address has to match what Messages stored — `+12025550143`, not `(555) 123-4567`
//  and not `2025550143`. Get it wrong and the send fails with "chat id not found", which
//  reads to a user like a conversation that has gone missing rather than a formatting bug.
//
//  This is the most testable part of the send path and it was the least tested: 13% covered,
//  against 99% for the script generation next to it. Nothing here needs Messages.app, a
//  signed-in account, or SIP disabled — it is pure string handling over a metadata bundle,
//  which is exactly the shape that should be pinned hardest.
//
//  Numbers below come from the ranges reserved for fiction, per CONTRIBUTING § Test data:
//  `NPA-555-0100`–`0199` in North America, and Ofcom's `020 7946 0xxx` / `07700 900xxx` in
//  the UK. None can ever route to a real person.

import Foundation
import Testing

@testable import BBAppleScript

/// Built once per region. `PhoneNumberUtility()` decodes a multi-megabyte metadata bundle in
/// its initialiser, which is the reason `AddressFormatter.shared` exists at all — building
/// one per test would dominate the suite's runtime.
private enum Formatters {
  static let us = AddressFormatter(defaultRegion: "US")
  static let gb = AddressFormatter(defaultRegion: "GB")
}

@Suite("Address slugging")
struct AddressSluggingTests {

  @Test(
    "Punctuation and spacing come out of a number, leaving digits and a leading +",
    arguments: [
      ("(202) 555-0143", "2025550143"),
      ("+1 (202) 555-0143", "+12025550143"),
      ("202.555.0143", "2025550143"),
      ("202 555 0143", "2025550143"),
      ("+1-202-555-0143", "+12025550143"),
    ])
  func numbersAreStripped(_ input: String, _ expected: String) {
    #expect(AddressFormatter.slugify(input) == expected)
  }

  @Test("An email keeps the punctuation an address needs and loses the rest")
  func emailPunctuation() {
    #expect(AddressFormatter.slugify("Someone@Example.COM") == "someone@example.com")
    #expect(AddressFormatter.slugify("first.last@example.com") == "first.last@example.com")
    #expect(AddressFormatter.slugify("first-last@example.com") == "first-last@example.com")
    #expect(AddressFormatter.slugify("first_last@example.com") == "first_last@example.com")
  }

  /// DOCUMENTING CURRENT BEHAVIOUR, not endorsing it.
  ///
  /// `+` is not in the allowed set for emails, so a plus-addressed mailbox is silently
  /// rewritten to a different one — `me+imessage@example.com` becomes
  /// `meimessage@example.com`, which is a real address belonging to somebody else's
  /// mailbox name. This is ported from the Node server's `slugifyAddress` and is a
  /// compatibility behaviour, not an oversight to fix casually; changing it changes which
  /// chat a send resolves to. Pinned here so the decision is deliberate either way.
  @Test("Plus-addressing is stripped from emails, as the Node server does")
  func plusAddressingIsStripped() {
    #expect(AddressFormatter.slugify("me+imessage@example.com") == "meimessage@example.com")
  }

  @Test("An empty address stays empty rather than becoming something else")
  func emptyIsPreserved() {
    #expect(AddressFormatter.slugify("") == "")
  }
}

@Suite("iMessage address format")
struct IMessageAddressFormatTests {

  @Test(
    "A North American number reaches E.164 however it was typed",
    arguments: [
      "(202) 555-0143",
      "202-555-0143",
      "2025550143",
      "+1 202 555 0143",
      "+12025550143",
      "1-202-555-0143",
    ])
  func northAmericanNumbers(_ input: String) {
    #expect(Formatters.us.iMessageFormat(input) == "+12025550143")
  }

  /// The reason this uses a phone-number library instead of prepending a calling code.
  ///
  /// Much of the world writes a national number with a trunk prefix that E.164 drops. The
  /// naive `"+44" + "02079460958"` gives `+44020…`, which Messages has never stored and
  /// which fails as "chat id not found".
  @Test(
    "A national trunk prefix is dropped, not concatenated",
    arguments: [
      ("02079460958", "+442079460958"),
      ("020 7946 0958", "+442079460958"),
      ("07700900123", "+447700900123"),
    ])
  func trunkPrefixIsDropped(_ input: String, _ expected: String) {
    #expect(Formatters.gb.iMessageFormat(input) == expected)
  }

  @Test("A number already in E.164 is not re-regionalised by the default region")
  func e164SurvivesForeignDefaultRegion() {
    // Parsed under GB, but the leading + means the country code is authoritative.
    #expect(Formatters.gb.iMessageFormat("+12025550143") == "+12025550143")
    #expect(Formatters.us.iMessageFormat("+442079460958") == "+442079460958")
  }

  @Test("An email is an identifier and passes through untouched")
  func emailsAreNotNumbers() {
    #expect(Formatters.us.iMessageFormat("someone@example.com") == "someone@example.com")
    #expect(Formatters.us.iMessageFormat("Someone@Example.com") == "someone@example.com")
  }

  /// Never throws, by contract: a send that fails is better than a send that never happens.
  @Test(
    "Something unparseable falls back to the slugged form instead of throwing",
    arguments: ["12", "0", "999", "notanumber"])
  func unparseableFallsBack(_ input: String) {
    let result = Formatters.us.iMessageFormat(input)
    #expect(result == AddressFormatter.slugify(input))
  }

  @Test("An empty address stays empty")
  func emptyStaysEmpty() {
    #expect(Formatters.us.iMessageFormat("") == "")
  }

  @Test("preSlugged skips the strip rather than doing it twice")
  func preSluggedIsHonoured() {
    #expect(Formatters.us.iMessageFormat("+12025550143", preSlugged: true) == "+12025550143")
  }
}

@Suite("Chat GUID normalisation")
struct ChatGUIDNormalisationTests {

  @Test("The address half is normalised and the service half is left alone")
  func directChatIsNormalised() {
    #expect(
      Formatters.us.normalizedChatGUID("iMessage;-;(202) 555-0143")
        == "iMessage;-;+12025550143")
    #expect(
      Formatters.us.normalizedChatGUID("SMS;-;2025550143") == "SMS;-;+12025550143")
  }

  /// A group identifier is opaque. Running it through a phone-number parser would corrupt
  /// it, and the corruption would present as a group chat that cannot be messaged.
  @Test(
    "A group identifier is returned untouched",
    arguments: [
      "iMessage;+;chat000000000000000001",
      "iMessage;-;chat000000000000000001",
    ])
  func groupsAreUntouched(_ guid: String) {
    #expect(Formatters.us.normalizedChatGUID(guid) == guid)
  }

  @Test(
    "Anything that is not a direct-chat GUID is returned untouched",
    arguments: [
      "not-a-guid",
      "iMessage;-;a;-;b",
      "",
    ])
  func malformedIsUntouched(_ guid: String) {
    #expect(Formatters.us.normalizedChatGUID(guid) == guid)
  }

  @Test("An email-addressed chat normalises without being parsed as a number")
  func emailChat() {
    #expect(
      Formatters.us.normalizedChatGUID("iMessage;-;someone@example.com")
        == "iMessage;-;someone@example.com")
  }
}

@Suite("GUID halves")
struct GUIDHalvesTests {

  @Test("The address is the last component, so an address containing ; is not truncated")
  func addressIsLastComponent() {
    #expect(AddressFormatter.address(from: "iMessage;-;+12025550143") == "+12025550143")
    #expect(AddressFormatter.address(from: "+12025550143") == "+12025550143")
  }

  @Test("A bare address carries no service and defaults to iMessage")
  func serviceDefaults() {
    #expect(AddressFormatter.service(from: "someone@example.com") == .iMessage)
    #expect(AddressFormatter.service(from: "SMS;-;+12025550143") == .sms)
  }
}
