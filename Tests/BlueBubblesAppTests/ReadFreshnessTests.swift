//  ReadFreshnessTests
//  When a page held on the model may show what it read last time instead of reading again.
//
//  `now` is a parameter throughout, which is what lets "thirty minutes later" be stated
//  rather than waited for.

import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Read freshness")
struct ReadFreshnessTests {

  private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
  private let halfHour: TimeInterval = 30 * 60

  @Test("Nothing is fresh before a read has been recorded")
  func nothingBeforeARead() {
    let freshness = ReadFreshness()
    #expect(!freshness.isFresh(for: "a", within: halfHour, now: start))
    #expect(freshness.readAt == nil)
  }

  @Test("The same key inside the age is fresh; past it, or another key, is not")
  func sameKeyInsideAge() {
    var freshness = ReadFreshness()
    freshness.record("a", at: start)

    #expect(freshness.isFresh(for: "a", within: halfHour, now: start + 60))
    #expect(freshness.isFresh(for: "a", within: halfHour, now: start + halfHour - 1))
    #expect(!freshness.isFresh(for: "a", within: halfHour, now: start + halfHour))
    // A different key is a different value, however recent: the range moved, or a version
    // the key follows did.
    #expect(!freshness.isFresh(for: "b", within: halfHour, now: start + 60))
  }

  /// The Refresh button re-reads for whatever the last visit asked, and a visit straight
  /// after it must find the value fresh rather than read a third time.
  @Test("A read with no key keeps the recorded key and moves the date")
  func refreshKeepsKey() {
    var freshness = ReadFreshness()
    freshness.record("a", at: start)
    freshness.record(nil, at: start + halfHour)

    #expect(freshness.isFresh(for: "a", within: halfHour, now: start + halfHour + 60))
    #expect(freshness.readAt == start + halfHour)
  }

  @Test("A read with no key before any keyed read is fresh for no key")
  func refreshBeforeAnyKey() {
    var freshness = ReadFreshness()
    freshness.record(nil, at: start)
    #expect(!freshness.isFresh(for: "a", within: halfHour, now: start + 1))
  }

  @Test("Invalidating forgets the read")
  func invalidate() {
    var freshness = ReadFreshness()
    freshness.record("a", at: start)
    freshness.invalidate()
    #expect(!freshness.isFresh(for: "a", within: halfHour, now: start + 1))
    #expect(freshness.readAt == nil)
  }
}
