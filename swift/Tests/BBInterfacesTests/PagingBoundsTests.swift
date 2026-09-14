//  PagingBoundsTests
//  Every paged query clamps its own limit, and none of them can be asked for "everything".
//
//  This is one defect that appeared in five places, and the reason it kept appearing is that
//  it does not look like a defect: the limit is passed to `LIMIT ?` and SQLite is trusted to
//  do something sensible with it. **SQLite reads a negative LIMIT as NO LIMIT**, so
//  `{"limit": -1}` did not fail and did not return nothing; it returned the entire table,
//  decoded it and serialised it into one response. On a real message database that is the
//  whole history, with attachments hydrated per row.
//
//  Three of the paged routes clamped and five did not, which is why this is asserted per
//  type rather than per route: the next paged query should have somewhere obvious to be
//  added, and a query type that forgets is what this catches.

import BBSerialization
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Paging bounds")
struct PagingBoundsTests {

  private static let cap = 1000

  // MARK: - Messages

  @Test("A negative message limit becomes one, not unbounded")
  func messageLimitFloor() {
    #expect(MessageInterface.Query(limit: -1).limit == 1)
    #expect(MessageInterface.Query(limit: Int.min).limit == 1)
    #expect(MessageInterface.Query(limit: 0).limit == 1)
  }

  @Test("A message limit past the cap is the cap")
  func messageLimitCeiling() {
    #expect(MessageInterface.Query(limit: Int.max).limit == Self.cap)
    #expect(MessageInterface.Query(limit: 100_000).limit == Self.cap)
  }

  @Test("An ordinary message limit is untouched")
  func messageLimitPassesThrough() {
    #expect(MessageInterface.Query(limit: 25).limit == 25)
    #expect(MessageInterface.Query(limit: Self.cap).limit == Self.cap)
  }

  @Test("A negative message offset becomes zero")
  func messageOffsetFloor() {
    // A negative OFFSET is a no-op in SQLite rather than a hazard, but it is still not a
    // page anybody can be on, and reporting it back in the metadata was confusing.
    #expect(MessageInterface.Query(offset: -5).offset == 0)
  }

  @Test("The body parser goes through the same clamp")
  func messageParseClamps() throws {
    // The route builds its query from a body, so the clamp has to be in the initialiser
    // rather than at the call site; this is what pins that.
    let query = try MessageInterface.Query.parse(.object(["limit": .int(-1)]))
    #expect(query.limit == 1)
  }

  // MARK: - Chats

  @Test("A negative chat limit becomes one, not unbounded")
  func chatLimitFloor() {
    #expect(ChatInterface.Query(limit: -1).limit == 1)
    #expect(ChatInterface.Query(limit: Int.min).limit == 1)
  }

  @Test("A chat limit past the cap is the cap")
  func chatLimitCeiling() {
    #expect(ChatInterface.Query(limit: Int.max).limit == Self.cap)
  }

  @Test("The chat body parser goes through the same clamp")
  func chatParseClamps() {
    #expect(ChatInterface.Query.parse(.object(["limit": .int(-1)])).limit == 1)
    #expect(ChatInterface.Query.parse(.object(["offset": .int(-1)])).offset == 0)
  }

  // MARK: - Handles

  @Test("The handle page helper clamps both ends")
  func handleClamp() {
    // This one was already right and is asserted so it stays the shared shape.
    #expect(HandleInterface.clampedPage(limit: -1, offset: -1) == (1, 0))
    #expect(HandleInterface.clampedPage(limit: Int.max, offset: 0).0 == Self.cap)
  }
}
