//  DateFieldParsingTests
//  `dateField` on the wire: absent and `created` are the reference's behaviour, the three
//  additions parse case-insensitively, and anything else is refused rather than defaulted.

import BBCore
import BBIMessage
import Testing

@testable import BBInterfaces

@Suite("dateField parsing")
struct DateFieldParsingTests {

  @Test("absent and created bracket on date, as the reference does")
  func defaults() throws {
    #expect(try MessageInterface.Query.dateField(named: nil) == .created)
    #expect(try MessageInterface.Query.dateField(named: "") == .created)
    #expect(try MessageInterface.Query.dateField(named: "created") == .created)
    #expect(try MessageInterface.Query.parse(.object([:])).dateField == .created)
  }

  @Test("the five additions parse, whatever the case")
  func additions() throws {
    #expect(try MessageInterface.Query.dateField(named: "delivered") == .delivered)
    #expect(try MessageInterface.Query.dateField(named: "Read") == .read)
    #expect(try MessageInterface.Query.dateField(named: "UPDATED") == .updated)
    #expect(try MessageInterface.Query.dateField(named: "edited") == .edited)
    #expect(try MessageInterface.Query.dateField(named: "retracted") == .retracted)
    let query = try MessageInterface.Query.parse(.object(["dateField": .string("read")]))
    #expect(query.dateField == .read)
  }

  @Test("an unknown value is refused, never read as the default")
  func unknownIsRefused() {
    #expect(throws: InterfaceError.self) {
      try MessageInterface.Query.dateField(named: "sent")
    }
    #expect(throws: InterfaceError.self) {
      try MessageInterface.Query.parse(.object(["dateField": .string("played")]))
    }
  }
}
