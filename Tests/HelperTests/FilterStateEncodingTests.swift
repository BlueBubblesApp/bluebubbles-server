//  FilterStateEncodingTests
//  What the helper puts on the wire for a chat's filter state.
//
//  macOS 27 has no `-[IMChat filterCategory]`, so the helper reads the category as nil there.
//  The wire has to carry that as a missing key, which `PrivateAPIClient` reads back as nil: a
//  0 would be indistinguishable from a chat that really is in the inbox. The helper encodes
//  with the contract's codec, so the codec is what is tested.

import BBPrivateAPIContract
import Testing

@Suite("Filter state encoding")
struct FilterStateEncodingTests {

  private func state(category: Int?) -> ChatFilterState {
    ChatFilterState(
      isFiltered: 0, filterCategory: category, isKnownSender: true,
      isInUnknownSendersFilter: false, wasDetectedAsSMSSpam: false, canReportJunk: false)
  }

  @Test("A known category goes on the wire")
  func knownCategory() {
    let object = state(category: 1).wire
    #expect(object[.filterCategory] as? Int == 1)
  }

  @Test("An unknown category is left off the wire, and nothing else is")
  func unknownCategory() {
    let object = state(category: nil).wire
    #expect(object[.filterCategory] == nil)
    #expect(object[.isFiltered] as? Int == 0)
    #expect(object[.isKnownSender] as? Bool == true)
  }
}
