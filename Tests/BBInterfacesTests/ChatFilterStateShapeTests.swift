//  ChatFilterStateShapeTests
//  `filter_category` is absent when the release cannot say, never a fabricated 0.
//
//  macOS 27 removed `-[IMChat filterCategory]` with nothing that reads a chat's category in its
//  place, so the helper reports no value there. The serializer has to carry that through as a
//  missing key: a 0 would tell a client every Junk conversation is in the inbox.

import BBPrivateAPIContract
import BBSerialization
import Testing

@testable import BBInterfaces

@Suite("Chat filter state shape")
struct ChatFilterStateShapeTests {

  private func state(category: Int?) -> ChatFilterState {
    ChatFilterState(
      isFiltered: 1, filterCategory: category, isKnownSender: false,
      isInUnknownSendersFilter: false, wasDetectedAsSMSSpam: false, canReportJunk: true)
  }

  @Test("A category the release reported is serialized")
  func knownCategory() {
    let json = ChatInterface.serialize(state(category: 2))
    #expect(json["filter_category"]?.intValue == 2)
    #expect(json["is_filtered"]?.intValue == 1)
  }

  @Test("A category the release cannot report is absent, not 0")
  func unknownCategory() {
    let json = ChatInterface.serialize(state(category: nil))
    #expect(json["filter_category"] == nil)
    // The rest of the answer survives one field the release cannot give.
    #expect(json["is_filtered"]?.intValue == 1)
    #expect(json["can_report_junk"] == .bool(true))
  }
}
