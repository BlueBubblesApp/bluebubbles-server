//  ContextCollaboratorTests
//  The two pieces of state that used to live on AppContext, and the rules they carry.

import BBEvents
import BBSerialization
import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

@Suite("Client activity tracker")
struct ClientActivityTrackerTests {

  @Test("Records the latest moment")
  func recordsLatest() {
    let tracker = ClientActivityTracker()
    #expect(tracker.last == nil)
    let first = Date(timeIntervalSince1970: 1_000)
    tracker.note(at: first)
    #expect(tracker.last == first)
  }

  @Test("Forwards at most once a minute, not once a request")
  func forwardsOncePerMinute() async throws {
    let tracker = ClientActivityTracker()
    let counter = Counter()
    tracker.setForwarder { await counter.increment() }

    let start = Date(timeIntervalSince1970: 10_000)
    tracker.note(at: start)
    tracker.note(at: start.addingTimeInterval(10))
    tracker.note(at: start.addingTimeInterval(59))
    tracker.note(at: start.addingTimeInterval(61))

    // The forwarder runs in a task of its own; give it a moment.
    try await Task.sleep(for: .milliseconds(50))
    #expect(await counter.value == 2)
  }

  @Test("Nothing is forwarded once push has gone")
  func noForwarderAfterWithdrawal() async throws {
    let tracker = ClientActivityTracker()
    let counter = Counter()
    tracker.setForwarder { await counter.increment() }
    tracker.setForwarder(nil)
    tracker.note()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await counter.value == 0)
  }

  private actor Counter {
    var value = 0
    func increment() { value += 1 }
  }
}

@Suite("Server address announcer")
struct ServerAddressAnnouncerTests {

  private actor RecordingSink: EventSink {
    let id: SinkID = .socket
    let projection: PayloadProjection = .full
    let routing = SinkRouting.socket
    var payloads: [JSONValue?] = []
    func accepts(_ event: ServerEvent) async -> Bool { true }
    func deliver(_ event: ServerEvent) async throws {
      payloads.append(event.payload(for: .full))
    }
  }

  /// Records every ATTEMPT, not every success, and can be told to fail the first few.
  ///
  /// The distinction is the whole point of the retry tests: a spy that only recorded what it
  /// accepted could not tell "published once" from "published on the fourth try", which is
  /// exactly the difference being asserted.
  private actor Published {
    private var failuresRemaining: Int
    var addresses: [String] = []

    init(failuresRemaining: Int = 0) {
      self.failuresRemaining = failuresRemaining
    }

    func record(_ address: String) -> Bool {
      addresses.append(address)
      guard failuresRemaining > 0 else { return true }
      failuresRemaining -= 1
      return false
    }
  }

  /// Fast enough to run, and still ordered, so "the schedule steps up" is exercised rather
  /// than collapsed to a single interval.
  private static let fastSchedule: [Duration] = [.milliseconds(1), .milliseconds(2)]

  @Test("Announces once per change, as a bare string, and publishes the same address")
  func announcesOnChange() async {
    let bus = EventBus()
    let sink = RecordingSink()
    await bus.register(sink)
    let published = Published()
    let announcer = ServerAddressAnnouncer(events: bus, logger: Logger(label: "test"))

    #expect(await announcer.announce(" https://a.example ") { await published.record($0) })
    // The same address again, in any whitespace, is not a change.
    #expect(await !announcer.announce("https://a.example\n") { await published.record($0) })
    #expect(await announcer.announce("https://b.example") { await published.record($0) })
    await bus.settle()

    #expect(await sink.payloads == [.string("https://a.example"), .string("https://b.example")])
    #expect(await published.addresses == ["https://a.example", "https://b.example"])
  }

  @Test("An empty address is not an announcement")
  func ignoresEmpty() async {
    let announcer = ServerAddressAnnouncer(events: EventBus(), logger: Logger(label: "test"))
    let published = Published()
    #expect(await !announcer.announce("   ") { await published.record($0) })
    #expect(await published.addresses.isEmpty)
  }

  @Test("A failed publish is retried until it lands")
  func retriesUntilPublished() async {
    // The defect this covers: the address was recorded as announced BEFORE the write was
    // attempted, and a failed write was logged and dropped. One three-second blip during a
    // tunnel's URL rotation stranded every client that was asleep until the next restart.
    let published = Published(failuresRemaining: 2)
    let announcer = ServerAddressAnnouncer(
      events: EventBus(),
      retrySchedule: Self.fastSchedule,
      steadyRetryInterval: .milliseconds(2),
      logger: Logger(label: "test"))

    #expect(await announcer.announce("https://a.example") { await published.record($0) })
    await announcer.settle()

    // Three attempts for one address: the original and two retries, the last of which stuck.
    #expect(
      await published.addresses == [
        "https://a.example", "https://a.example", "https://a.example",
      ])
  }

  @Test("Retrying outlasts the stepped schedule and keeps going at the steady interval")
  func retriesPastTheSchedule() async {
    // Four failures against a two-entry schedule, so the fifth attempt can only have been
    // made on the steady interval. Without that tail the retry would stop after the last
    // scheduled delay, which is the same permanent-outage bug one step further out.
    let published = Published(failuresRemaining: 4)
    let announcer = ServerAddressAnnouncer(
      events: EventBus(),
      retrySchedule: Self.fastSchedule,
      steadyRetryInterval: .milliseconds(1),
      logger: Logger(label: "test"))

    #expect(await announcer.announce("https://a.example") { await published.record($0) })
    await announcer.settle()

    #expect(await published.addresses.count == 5)
  }

  @Test("A newer address supersedes a retry still chasing the old one")
  func newerAddressSupersedesRetry() async {
    // A tunnel that rotates twice while the network is down must not leave a task writing the
    // address from two rotations ago on top of the current one.
    let published = Published(failuresRemaining: 1)
    let announcer = ServerAddressAnnouncer(
      events: EventBus(),
      retrySchedule: [.milliseconds(80)],
      steadyRetryInterval: .milliseconds(80),
      logger: Logger(label: "test"))

    #expect(await announcer.announce("https://old.example") { await published.record($0) })
    // Arrives while the first retry is still asleep.
    #expect(await announcer.announce("https://new.example") { await published.record($0) })
    await announcer.settle()

    // The old address was attempted once and never again; the new one succeeded outright.
    #expect(
      await published.addresses == ["https://old.example", "https://new.example"])
  }
}
