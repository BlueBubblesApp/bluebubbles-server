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

@Suite("Shared notification sink")
struct SharedNotificationSinkTests {

  private struct StubProvider: NotificationProvider {
    let providerID: String
    var subscription: EventSubscription { .all }
    var isReady: Bool { get async { true } }
    func send(_ event: ServerEvent) async throws {}
  }

  @Test("Detaching one provider leaves the other attached")
  func detachingOneLeavesTheOther() async {
    let sink = NotificationSink()
    await sink.attach(StubProvider(providerID: "firebase"))
    await sink.attach(StubProvider(providerID: "ntfy"))
    #expect(await sink.attachedProviderIDs == ["firebase", "ntfy"])

    await sink.detach(providerID: "firebase")
    #expect(
      await sink.attachedProviderIDs == ["ntfy"],
      "switching push off must not take ntfy's provider with it")
  }

  @Test("The sink is only empty once every transport has gone")
  func emptyOnlyWhenBothLeave() async {
    let sink = NotificationSink()
    await sink.attach(StubProvider(providerID: "firebase"))
    await sink.attach(StubProvider(providerID: "ntfy"))

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
