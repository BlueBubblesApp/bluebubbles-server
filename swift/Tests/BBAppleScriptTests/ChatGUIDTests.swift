//  ChatGUIDTests
//  The macOS 26 service-prefix migration.
//
//  NO REAL ADDRESSES. Every address here is from a range reserved for documentation —
//  `example.com` (RFC 2606) and the fictional `NPA-555-0100..0199` phone block — so nothing
//  in this repository can be traced to anyone's address book. A test that genuinely needs a
//  live chat reads its GUID from the `BB_LIVE_SEND_GUID` environment variable and is skipped
//  when it is unset; see LiveSendTests.
//
//  Verified against a live macOS 26.5.2 chat.db: 479/479 chat rows carry the `any` prefix,
//  0 carry a legacy one, and 325 of those chats hold pre-2023 messages — so historical rows
//  were rewritten, not merely new ones created. Every GUID a client cached is stale.

import BBCore
import Testing

@Suite("Chat GUID parsing")
struct ChatGUIDParsingTests {

  @Test("A direct-chat GUID parses into its three parts")
  func parsesDirect() throws {
    let guid = try #require(ChatGUID("iMessage;-;+12025550143"))
    #expect(guid.servicePrefix == "iMessage")
    #expect(guid.separator == .direct)
    #expect(guid.address == "+12025550143")
    #expect(!guid.isGroup)
    #expect(guid.declaredService == .iMessage)
  }

  @Test("A group GUID is recognised by its separator")
  func parsesGroup() throws {
    let guid = try #require(ChatGUID("iMessage;+;chat000000000000000001"))
    #expect(guid.separator == .group)
    #expect(guid.isGroup)
    #expect(guid.address == "chat000000000000000001")
  }

  /// The macOS 26 form. The prefix names no service, which is not a parse failure — the
  /// service moved to `chat.service_name`.
  @Test("The macOS 26 `any` prefix parses and reports no declared service")
  func parsesAnyPrefix() throws {
    let guid = try #require(ChatGUID("any;-;someone@example.com"))
    #expect(guid.hasAnyServicePrefix)
    #expect(guid.declaredService == nil)
    #expect(guid.address == "someone@example.com")
  }

  @Test("A malformed GUID does not parse")
  func rejectsMalformed() {
    #expect(ChatGUID("not-a-guid") == nil)
    #expect(ChatGUID("iMessage;+12025550143") == nil)
    // An unknown separator is not silently treated as direct.
    #expect(ChatGUID("iMessage;?;+12025550143") == nil)
  }

  /// An address containing a semicolon must not be truncated by the split.
  @Test("An address is rejoined rather than truncated")
  func rejoinsAddress() throws {
    let guid = try #require(ChatGUID("iMessage;-;odd;address"))
    #expect(guid.address == "odd;address")
  }
}

@Suite("Service-prefix tolerance")
struct ServicePrefixToleranceTests {

  /// The property the whole compatibility layer rests on.
  @Test("The same chat under different service prefixes compares equal")
  func sameChatAcrossPrefixes() {
    #expect(ChatGUID.sameChat("iMessage;-;+12025550143", "any;-;+12025550143"))
    #expect(ChatGUID.sameChat("SMS;-;+12025550143", "any;-;+12025550143"))
    #expect(ChatGUID.sameChat("any;+;chat123", "iMessage;+;chat123"))
  }

  /// Tolerance stops at the prefix. A different address, or a group versus a direct chat,
  /// are different chats.
  @Test("Tolerance does not extend past the prefix")
  func toleranceIsNarrow() {
    #expect(!ChatGUID.sameChat("iMessage;-;+12025550143", "any;-;+12025550199"))
    #expect(!ChatGUID.sameChat("iMessage;-;chat123", "iMessage;+;chat123"))
  }

  /// One SQL `IN (...)` rather than a query-then-retry, so a miss costs no extra round trip.
  @Test("Lookup candidates cover every spelling, caller's own first")
  func lookupCandidates() throws {
    let candidates = try #require(ChatGUID("iMessage;-;+12025550143")).lookupCandidates()

    #expect(candidates.first == "iMessage;-;+12025550143")
    #expect(candidates.contains("any;-;+12025550143"))
    #expect(candidates.contains("SMS;-;+12025550143"))
    // No duplicate of the caller's own spelling.
    #expect(Set(candidates).count == candidates.count)
  }

  @Test("An `any` GUID still offers the legacy spellings, for an unmigrated database")
  func anyPrefixOffersLegacy() throws {
    let candidates = try #require(ChatGUID("any;-;x@example.com")).lookupCandidates()
    #expect(candidates.first == "any;-;x@example.com")
    #expect(candidates.contains("iMessage;-;x@example.com"))
  }
}
