//  ContactStoreWatchTests
//  The address book changing underneath a running server.
//
//  Until this existed, a removal was noticed only at start-up or on a manual Refresh:
//  `reindexAll` rebuilds the index by deleting every address-book row and re-inserting what
//  Contacts hands over, so a deleted contact — or an account someone unlinked — stops being
//  returned. Nothing triggered it. `CNContactStoreDidChange` appeared in this codebase only
//  inside a comment, so a server left running for weeks went on serving contacts the Mac no
//  longer had, and on turning their handles into names.
//
//  What is asserted here is the DEBOUNCE, because that is the part with a decision in it. The
//  notification says only that something changed, never what, and unlinking an account
//  delivers one per contact removed: acting on each would walk the whole address book dozens
//  of times during a single sync. Driving the real `CNContactStore` from a test is not
//  something a test process can do, so the coalescing is asserted against the operator the
//  service uses.

import BBCore
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Address-book change watching")
struct ContactStoreWatchTests {

  /// A burst collapses to one pass. This is the property the design rests on.
  @Test("A burst of changes produces a single re-index")
  func burstCoalesces() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let debounced = stream.debounce(for: .milliseconds(120))

    // What unlinking an account looks like: many notifications, no gap between them.
    for _ in 0..<50 { continuation.yield(()) }
    continuation.finish()

    var passes = 0
    for await _ in debounced { passes += 1 }
    #expect(passes == 1, "fifty notifications produced \(passes) re-indexes of the address book")
  }

  /// And a quiet period between two edits is two passes: coalescing must not swallow a change
  /// somebody makes later, which would leave the index stale until the next restart.
  ///
  /// Driven by AWAITING each element rather than by sleeping between yields. A fixed sleep
  /// makes the quiet period a race against the scheduler: this test passed on its own and
  /// failed in a full run, where the collector was not resumed before the second yield and the
  /// two collapsed into one window. `UnreadableSecretTests` records the same trap.
  ///
  /// The time limit is what turns a debounce that never fires into a failure rather than a
  /// hung suite.
  @Test("Changes separated by a quiet period are acted on separately", .timeLimit(.minutes(1)))
  func separatedChangesBothLandTest() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    var iterator = stream.debounce(for: .milliseconds(60)).makeAsyncIterator()

    continuation.yield(())
    let first: Void? = await iterator.next()
    // Only once the first has actually been delivered, which is what "a quiet period" means
    // here: no wall-clock assumption about when that happens.
    continuation.yield(())
    let second: Void? = await iterator.next()
    continuation.finish()

    #expect(first != nil)
    #expect(second != nil, "a change made after the first pass was swallowed by the debounce")
  }

  /// The interval is a decision with a cost on each side, so it is named rather than inline.
  @Test("The debounce is long enough to outlast a sync and short enough to feel immediate")
  func debounceIsStated() {
    #expect(ContactsService.changeDebounce >= .seconds(5), "too short to outlast an account sync")
    #expect(
      ContactsService.changeDebounce <= .seconds(30),
      "an edit made now should be reflected while the person who made it is still looking")
  }
}
