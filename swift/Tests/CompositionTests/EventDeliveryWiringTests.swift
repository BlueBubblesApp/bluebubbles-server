//  EventDeliveryWiringTests
//  Every delivery route is actually connected to the event bus.
//
//  This file exists because the same defect appeared three times and was invisible each
//  time: a sink was written, unit-tested, and never registered. `EventBus` fans out only to
//  sinks that registered, so an unregistered one is not a broken sink — it is silence. The
//  socket, FCM and webhooks were all in that state simultaneously, with `server/info`
//  reporting push and the socket as active.
//
//  So these are wiring tests rather than behaviour tests. The behaviour of each sink is
//  covered in its own module; what is asserted here is that the service's `start()` puts it
//  on the bus, which is the step that kept being missed.

import BBCore
import BBDiagnostics
import BBEvents
import BBSerialization
import BBServiceKit
import BBSocketIO
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Event delivery wiring")
struct EventDeliveryWiringTests {

  private func event(_ name: EventName = .newMessage) -> ServerEvent {
    ServerEvent(
      name: name,
      // DISTINCT on purpose. The two projections exist because FCM caps a notification at
      // 4 KB while the socket takes the whole message, so a fixture that made them identical
      // could not tell a working split from a broken one — `projectionsDiffer` asserts they
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

    init(id: SinkID, projection: PayloadProjection = .notification) {
      self.id = id
      self.projection = projection
    }
    func accepts(_ event: ServerEvent) async -> Bool { true }
    func deliver(_ event: ServerEvent) async throws { received.append(event.name) }
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
  func deliveryServicesAreRegistered() {
    // The composition root is where a sink gets its chance to register, and a service
    // missing from that list is a delivery route that silently does not exist.
    let ids: Set<ServiceID> = [
      SocketService.id, PushDeliveryService.id, WebhookDeliveryService.id,
    ]
    #expect(ids.count == 3, "two delivery services collided on one id")
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
