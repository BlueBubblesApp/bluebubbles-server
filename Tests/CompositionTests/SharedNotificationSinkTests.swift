//  SharedNotificationSinkTests
//  Switching one notification transport off does not take the other with it.
//
//  `NotificationSink` is ONE object with ONE `SinkID`, and two services register it: push
//  attaches Firebase, the webhook service attaches ntfy. `EventBus.unregister` removes the
//  whole lane, so `PushDeliveryService.stop` pulling the sink off the bus silently stopped
//  ntfy delivery too — while the webhook service went on reporting `.running`, and nothing
//  came back until that service happened to restart.
//
//  The webhook service already had this right and said so in place; push was the asymmetric
//  one. What is pinned here is the rule rather than either implementation: the lane belongs
//  to whichever services still have a provider attached, so it goes only when the last one
//  leaves.

import BBEvents
import BBPushKit
import Testing

/// Ready, subscribed to everything, and drops what it is sent: these suites assert on which
/// providers are attached, never on delivery.
private struct InertProvider: NotificationProvider {
  let providerID: String
  var subscription: EventSubscription { .all }
  var isReady: Bool { get async { true } }
  func send(_ event: ServerEvent) async throws {}
}

@Suite("Shared notification sink")
struct SharedNotificationSinkTests {

  @Test("Detaching one provider leaves the other attached")
  func detachingOneLeavesTheOther() async {
    let sink = NotificationSink()
    await sink.attach(InertProvider(providerID: "firebase"))
    await sink.attach(InertProvider(providerID: "ntfy"))
    #expect(await sink.attachedProviderIDs == ["firebase", "ntfy"])

    await sink.detach(providerID: "firebase")
    #expect(
      await sink.attachedProviderIDs == ["ntfy"],
      "switching push off must not take ntfy's provider with it")
  }

  @Test("The sink is only empty once every transport has gone")
  func emptyOnlyWhenBothLeave() async {
    let sink = NotificationSink()
    await sink.attach(InertProvider(providerID: "firebase"))
    await sink.attach(InertProvider(providerID: "ntfy"))

    await sink.detach(providerID: "firebase")
    #expect(
      await !sink.attachedProviderIDs.isEmpty,
      "the lane must stay on the bus while ntfy is still attached")

    await sink.detach(providerID: "ntfy")
    #expect(
      await sink.attachedProviderIDs.isEmpty,
      "and it may leave once nothing is attached")
  }

  /// The two services must agree on the spelling, or one detaches a provider that is not
  /// there and leaves the real one delivering after its service has stopped.
  @Test("The provider identifiers the two services use are the ones the providers declare")
  func identifiersAgree() {
    #expect(FirebaseProvider.identifier == "firebase")
    #expect(NtfyProvider.identifier == "ntfy")
  }
}

@Suite("Shared notification lane on the bus")
struct SharedNotificationLaneTests {

  @Test("The lane stays on the bus until the last transport leaves")
  func laneOutlivesAllButTheLast() async {
    let bus = EventBus()
    let sink = NotificationSink()
    await sink.join(InertProvider(providerID: "firebase"), on: bus)
    await sink.join(InertProvider(providerID: "ntfy"), on: bus)
    #expect(await bus.activeSinks == [sink.id])

    await sink.leave(providerID: "firebase", from: bus)
    #expect(await bus.activeSinks == [sink.id], "ntfy is still attached, so the lane stays")

    await sink.leave(providerID: "ntfy", from: bus)
    #expect(await bus.activeSinks.isEmpty)
  }
}
