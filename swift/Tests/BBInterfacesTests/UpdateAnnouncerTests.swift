//  UpdateAnnouncerTests
//  `server-update` goes out once per version, as the bare version string.
//
//  Three paths can find the same release on the same day. The clients show a notification
//  for every emit, so the count is the contract here, and the payload shape is the wire.

import BBEvents
import BBSerialization
import Testing

@testable import BBInterfaces

@Suite("Update announcer")
struct UpdateAnnouncerTests {

  private actor CapturingSink: EventSink {
    nonisolated let id: SinkID = .socket
    nonisolated let projection: PayloadProjection = .full
    nonisolated let routing: SinkRouting = .socket
    private(set) var events: [ServerEvent] = []
    func accepts(_ event: ServerEvent) async -> Bool { true }
    func deliver(_ event: ServerEvent) async { events.append(event) }
  }

  @Test("The same version announces once; a newer one announces again")
  func oncePerVersion() async {
    let bus = EventBus()
    let sink = CapturingSink()
    await bus.register(sink)
    let announcer = UpdateAnnouncer(events: bus)

    #expect(await announcer.announce(version: "1.3.0"))
    #expect(!(await announcer.announce(version: "1.3.0")))
    #expect(!(await announcer.announce(version: " 1.3.0 ")))
    #expect(await announcer.announce(version: "1.4.0"))
    #expect(!(await announcer.announce(version: "")))
    await bus.settle()

    let events = await sink.events
    #expect(events.map(\.name) == [.serverUpdate, .serverUpdate])
    // The bare string, matching `emitMessage(SERVER_UPDATE, latestVersion)`.
    #expect(events.map(\.fullPayload) == [.string("1.3.0"), .string("1.4.0")])
  }
}
