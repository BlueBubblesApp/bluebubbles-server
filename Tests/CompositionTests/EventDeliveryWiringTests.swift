//  EventDeliveryWiringTests
//  Every delivery route is actually connected to the event bus.
//
//  This file exists because the same defect appeared three times and was invisible each
//  time: a sink was written, unit-tested, and never registered. `EventBus` fans out only to
//  sinks that registered, so an unregistered one is not a broken sink; it is silence. The
//  socket, FCM and webhooks were all in that state simultaneously, with `server/info`
//  reporting push and the socket as active.
//
//  So these are wiring tests rather than behaviour tests. The behaviour of each sink is
//  covered in its own module; what is asserted here is that each one is REGISTERED with the
//  composition root at all, which is the step that kept being missed: an unregistered
//  service never starts, so its `start()` never reaches the bus.

import BBCore
import BBDiagnostics
import BBEvents
import BBPersistence
import BBSerialization
import BBServiceKit
import BBSocketIO
import BBTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import BBHandlers
@testable import BBIMessage
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Event delivery wiring")
struct EventDeliveryWiringTests {

  private func event(_ name: EventName = .newMessage) -> ServerEvent {
    ServerEvent(
      name: name,
      // DISTINCT on purpose. The two projections exist because FCM caps a notification at
      // 4 KB while the socket takes the whole message, so a fixture that made them identical
      // could not tell a working split from a broken one; `projectionsDiffer` asserts they
      // differ, and with equal payloads that assertion can never hold however correct the
      // code is.
      fullPayload: .object([
        "guid": .string("MSG-1"),
        "text": .string("the full body the socket receives"),
      ]),
      notificationPayload: .object(["guid": .string("MSG-1")])
    )
  }

  /// Counts what reached it, so a test can tell "delivered" from "registered".
  private actor CountingSink: EventSink {
    nonisolated let id: SinkID
    nonisolated let projection: PayloadProjection
    nonisolated let routing = SinkRouting.webhook
    private(set) var received: [EventName] = []
    private(set) var payloads: [JSONValue] = []

    init(id: SinkID, projection: PayloadProjection = .notification) {
      self.id = id
      self.projection = projection
    }
    func accepts(_ event: ServerEvent) async -> Bool { true }
    func deliver(_ event: ServerEvent) async throws {
      received.append(event.name)
      payloads.append(event.payload(for: projection))
    }
  }

  @Test("A registered sink receives an emitted event")
  func registeredSinkReceives() async {
    let bus = EventBus()
    let sink = CountingSink(id: .webhook)
    await bus.register(sink)

    await bus.emit(event())
    await bus.settle()
    #expect(await sink.received == [.newMessage])
  }

  @Test("An unregistered sink receives nothing, silently")
  func unregisteredSinkIsSilent() async {
    // The shape of the defect: no error, no warning, no delivery. Pinned so the failure
    // mode is at least documented in a test rather than only in a postmortem.
    let bus = EventBus()
    let sink = CountingSink(id: .webhook)

    await bus.emit(event())
    await bus.settle()
    #expect(await sink.received.isEmpty)
    #expect(await bus.activeSinks.isEmpty)
  }

  @Test("Unregistering stops delivery")
  func unregisterStopsDelivery() async {
    // What each service's `stop()` relies on. A sink left registered after its service
    // stopped would keep being delivered to through a dead client.
    let bus = EventBus()
    let sink = CountingSink(id: .push)
    await bus.register(sink)
    await bus.emit(event())
    await bus.settle()

    await bus.unregister(.push)
    await bus.emit(event())
    await bus.settle()

    #expect(await sink.received.count == 1)
    #expect(await bus.activeSinks.isEmpty)
  }

  @Test("Every route gets the same event")
  func allRoutesReceiveTheSameEvent() async {
    // No route is primary. A socket-only install, a webhook-only install and a full FCM
    // install are all supported, and an event goes to whichever are present.
    let bus = EventBus()
    let socket = CountingSink(id: .socket, projection: .full)
    let push = CountingSink(id: .push)
    let webhook = CountingSink(id: .webhook)
    for sink in [socket, push, webhook] { await bus.register(sink) }

    await bus.emit(event())
    await bus.settle()

    #expect(await socket.received == [.newMessage])
    #expect(await push.received == [.newMessage])
    #expect(await webhook.received == [.newMessage])
  }

  @Test("One failing sink does not stop the others")
  func oneFailingSinkIsIsolated() async {
    // A webhook endpoint that hangs cannot delay socket delivery, and an FCM outage
    // cannot stop webhooks.
    struct ThrowingSink: EventSink {
      let id = SinkID.webhook
      let projection = PayloadProjection.notification
      let routing = SinkRouting.webhook
      func accepts(_ event: ServerEvent) async -> Bool { true }
      func deliver(_ event: ServerEvent) async throws {
        struct Boom: Error {}
        throw Boom()
      }
    }

    let bus = EventBus()
    let socket = CountingSink(id: .socket, projection: .full)
    await bus.register(ThrowingSink())
    await bus.register(socket)

    await bus.emit(event())
    await bus.settle()
    #expect(await socket.received == [.newMessage])
  }

  @Test("Push and the socket ask for different payloads")
  func projectionsDiffer() async {
    // The socket takes the FULL payload and everything else takes the trimmed one.
    // FCM has a 4 KB limit, so sending it the full body silently exceeds the limit and
    // the notification is dropped by Google rather than rejected by us.
    #expect(SocketSink(server: SocketServer()).projection == .full)

    let event = event()
    // `payload(for:)` is non-optional, so asserting it is non-nil asserted nothing.
    // What the projections are for is that they DIFFER.
    #expect(event.payload(for: .full) != event.payload(for: .notification))
  }

  // MARK: - Service registration

  @Test("Every delivery service is registered with the registry")
  func deliveryServicesAreRegistered() async throws {
    // DRIVES THE REAL REGISTRATION. This asserted that a three-element set built from three
    // static identifiers had three elements in it, which is true of any three distinct
    // constants and says nothing about the composition root: deleting
    // `registry.register(PushDeliveryService.self)` left it green. Nothing else tested
    // `registerServices` either, so the one step this whole file exists to cover was
    // covered by nobody.
    //
    // It matters more than a single stale test, because `CLAUDE.md` names this file as THE
    // pattern for wiring assertions and tells other tests to copy it.
    let registry = ServiceRegistry<AppContext>(host: try await AppContextFixture.make())
    await ServerComposition.registerServices(in: registry)

    let registered = Set(await registry.manifests.map(\.id))
    for id in [SocketService.id, PushDeliveryService.id, WebhookDeliveryService.id] {
      #expect(
        registered.contains(id),
        "\(id.rawValue) is not registered, so its delivery route silently does not exist"
      )
    }
    // And they are three different services rather than one id written three times.
    #expect(
      Set([SocketService.id, PushDeliveryService.id, WebhookDeliveryService.id]).count == 3,
      "two delivery services collided on one id"
    )
  }

  // MARK: - Chat read status

  /// `chat-read-status-changed` was declared, catalogued and offered to webhooks, and emitted
  /// by nothing. This drives the whole path but the file watcher: the service is registered,
  /// its detector finds a read written into a `chat.db`, and the step its pump runs puts it
  /// on every route with the reference's payload.
  @Test("A chat read in chat.db reaches every route as chat-read-status-changed")
  func chatReadReachesEveryRoute() async throws {
    let registry = ServiceRegistry<AppContext>(host: try await AppContextFixture.make())
    await ServerComposition.registerServices(in: registry)
    #expect(
      Set(await registry.manifests.map(\.id)).contains(ChangeDetectionService.id),
      "change detection is not registered, so no chat read is ever announced")

    try await CommittedChatDB.withCopies {
      let path = try CommittedChatDB.copy(.sonoma).path
      let database = try ReadOnlyDatabase(path: path)
      let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
      let start = Date()
      let detector = ChangeDetector(
        repository: MessageRepository(database: database, profile: profile),
        startingFrom: start)
      _ = try await detector.tick(now: start)

      // Written on the throwaway copy, as Messages would write the real one.
      let writer = try DatabaseQueue(path: path)
      let readAt = AppleTimestamp.from(start.addingTimeInterval(1), unit: .nanoseconds)
      let guid = try await writer.write { db in
        try db.execute(
          sql: "UPDATE chat SET last_read_message_timestamp = ? WHERE ROWID = 1",
          arguments: [readAt.rawValue])
        return try String.fetchOne(db, sql: "SELECT guid FROM chat WHERE ROWID = 1")
      }
      try writer.close()
      let batch = try await detector.tick(now: start.addingTimeInterval(2))
      #expect(batch.chatReads.count == 1)

      let bus = EventBus()
      let socket = CountingSink(id: .socket, projection: .full)
      let push = CountingSink(id: .push)
      let webhook = CountingSink(id: .webhook)
      for sink in [socket, push, webhook] { await bus.register(sink) }
      await ChangeDetectionService.announce(
        chatReads: batch.chatReads, to: bus, logger: Logger(label: "test"))
      await bus.settle()

      let expected = JSONValue.object([
        "chatGuid": .string(try #require(guid)), "read": .bool(true),
      ])
      for sink in [socket, push, webhook] {
        #expect(await sink.received == [.chatReadStatusChanged])
        #expect(await sink.payloads == [expected])
      }
    }
  }

  /// Mark-unread is the one `read: false` there is: chat.db detection only sees a chat's read
  /// time RISE, and marking a chat unread does not move it. So the interface announces it, and
  /// this drives the interface the composition root builds, on the bus it builds.
  @Test("Marking a chat unread reaches every route as read: false")
  func markUnreadReachesEveryRoute() async throws {
    let context = try await AppContextFixture.make(withMessageAccess: true)
    var helper = FailingPrivateAPI()
    helper.succeeding = [.markUnread]
    await context.publishPrivateAPI(client: helper, runtime: nil)
    let socket = CountingSink(id: .socket, projection: .full)
    let push = CountingSink(id: .push)
    let webhook = CountingSink(id: .webhook)
    for sink in [socket, push, webhook] { await context.events.register(sink) }

    let guid = "iMessage;-;person@example.com"
    try await context.requireInterfaces().chat.markUnread(guid: guid)
    await context.events.settle()

    let expected = JSONValue.object(["chatGuid": .string(guid), "read": .bool(false)])
    for sink in [socket, push, webhook] {
      #expect(await sink.received == [.chatReadStatusChanged])
      #expect(await sink.payloads == [expected])
    }
  }

  @Test("A mark-unread Messages refused announces nothing")
  func refusedMarkUnreadIsSilent() async throws {
    let context = try await AppContextFixture.make(withMessageAccess: true)
    await context.publishPrivateAPI(client: FailingPrivateAPI(), runtime: nil)
    let webhook = CountingSink(id: .webhook)
    await context.events.register(webhook)

    await #expect(throws: (any Error).self) {
      try await context.requireInterfaces().chat.markUnread(guid: "iMessage;-;person@example.com")
    }
    await context.events.settle()
    #expect(await webhook.received.isEmpty)
  }

  @Test("The chat read event is the reference's: one payload, normal priority")
  func chatReadEventShape() {
    let event = ChangeDetectionService.event(
      forChatRead: ChatReadMark(
        rowID: 7, guid: "iMessage;-;+12025550143",
        lastRead: AppleTimestamp(rawValue: 1, unit: .nanoseconds)))
    let expected = JSONValue.object([
      "chatGuid": .string("iMessage;-;+12025550143"), "read": .bool(true),
    ])
    #expect(event.name.rawValue == "chat-read-status-changed")
    #expect(event.fullPayload == expected)
    #expect(event.notificationPayload == expected)
    #expect(event.priority == .normal)
  }

  @Test("A delivery service does not depend on another route being present")
  func routesAreIndependent() {
    // A socket-only install must not need push, and a webhook-only install must not need
    // either. Dependencies between them would make one missing route disable the rest.
    #expect(!PushDeliveryService.dependencies.contains(SocketService.id))
    #expect(!WebhookDeliveryService.dependencies.contains(SocketService.id))
    #expect(WebhookDeliveryService.dependencies.isEmpty)
    #expect(PushDeliveryService.dependencies.isEmpty)
  }
}
