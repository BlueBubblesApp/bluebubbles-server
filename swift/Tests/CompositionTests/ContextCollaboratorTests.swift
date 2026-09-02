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

  private actor Published {
    var addresses: [String] = []
    func record(_ address: String) { addresses.append(address) }
  }

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
}
