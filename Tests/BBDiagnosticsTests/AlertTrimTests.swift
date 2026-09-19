//  AlertTrimTests
//  An alert the centre removes is announced, and forgotten from the dedupe index.
//
//  The drawer seeds itself once and then follows `stream()` and `dismissals()`, which is
//  exactly why `dismissals()` exists. The retention trim removed rows without announcing
//  them, so an expired alert stayed on screen until the window was reopened: the same bug
//  the dismissal stream was added to fix, arriving by a different route.
//
//  Leaving the dedupe entry behind is the quieter half: the next raise of that key updates a
//  row that is no longer in the list, so the alert never appears at all.

import BBCore
import Foundation
import Testing

@testable import BBDiagnostics

@Suite("Alert trimming")
struct AlertTrimTests {

  /// A clock the test moves, so a thirty-day retention does not take thirty days.
  private final class TestClock: BBClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(by interval: TimeInterval) {
      lock.withLock { current = current.addingTimeInterval(interval) }
    }
  }

  private func alert(_ title: String, dedupeKey: String? = nil) -> UserAlert {
    UserAlert(severity: .warning, title: title, body: "b", source: "test", dedupeKey: dedupeKey)
  }

  @Test("An expired alert is announced as dismissed")
  func expiryIsAnnounced() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let centre = AlertCenter(capacity: 100, retention: .seconds(60), clock: clock)

    await centre.raise(alert("old"))
    let stale = try #require(await centre.all().first)

    let dismissals = await centre.dismissals()
    clock.advance(by: 120)
    // Any raise runs the trim; this is the one the drawer would be watching for.
    await centre.raise(alert("new"))

    var announced: [UUID] = []
    for await batch in dismissals {
      announced.append(contentsOf: batch)
      break
    }
    #expect(announced.contains(stale.id), "an expired alert must be withdrawn, not just dropped")
  }

  @Test("An expired alert's dedupe key is forgotten, so the next one appears")
  func expiryClearsTheIndex() async throws {
    let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let centre = AlertCenter(capacity: 100, retention: .seconds(60), clock: clock)

    await centre.raise(alert("first", dedupeKey: "proxy.down"))
    clock.advance(by: 120)
    await centre.raise(alert("filler"))

    // The same key again. With the index entry left behind, this coalesced onto a row that
    // is no longer in the list and the user saw nothing at all.
    await centre.raise(alert("second", dedupeKey: "proxy.down"))

    let titles = await centre.all().map(\.title)
    #expect(titles.contains("second"), "a re-raised alert after expiry must appear; got \(titles)")
  }

  @Test("A live alert is neither dismissed nor forgotten")
  func liveAlertsAreUntouched() async throws {
    // The other half: the trim must not announce rows that are still current.
    let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
    let centre = AlertCenter(capacity: 100, retention: .seconds(3600), clock: clock)

    await centre.raise(alert("current", dedupeKey: "still.here"))
    clock.advance(by: 60)
    await centre.raise(alert("another"))

    #expect(await centre.all().count == 2)
    // And the key still coalesces rather than adding a third row.
    await centre.raise(alert("current", dedupeKey: "still.here"))
    #expect(await centre.all().count == 2)
  }
}
