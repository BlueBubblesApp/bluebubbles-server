//  NotificationSinkTests
//  One sink, many transports, and the routing policy written once.
//
//  Firebase and ntfy were two sinks with two copies of the policy, and the copies had already
//  drifted: `PushSink` routed `.push` and `NtfySink` routed `.webhook`, so the same ntfy topic
//  received a different event set depending on how it had been configured.
//
//  What is asserted here is the part that is easy to get wrong and invisible when it is: a
//  provider that fails must not take the others down with it, and a subscription must be able
//  to narrow without being able to widen.

import Foundation
import Testing

@testable import BBEvents

private actor Recorder {
  private(set) var received: [String] = []
  func record(_ name: String) { received.append(name) }
}

private struct StubProvider: NotificationProvider {
  let providerID: String
  var subscription: EventSubscription = .all
  var ready = true
  var failure: (any Error)?
  let recorder: Recorder

  var isReady: Bool { get async { ready } }

  func send(_ event: ServerEvent) async throws {
    if let failure { throw failure }
    await recorder.record("\(providerID):\(event.name.rawValue)")
  }
}

private struct Boom: Error {}

private func event(_ name: EventName) -> ServerEvent {
  ServerEvent(name: name, fullPayload: .object([:]))
}

@Suite("Notification sink")
struct NotificationSinkTests {

  @Test("Every ready provider receives the event")
  func fansOutToAll() async throws {
    let recorder = Recorder()
    let sink = NotificationSink()
    await sink.attach(StubProvider(providerID: "firebase", recorder: recorder))
    await sink.attach(StubProvider(providerID: "ntfy", recorder: recorder))

    try await sink.deliver(event(.newMessage))
    #expect(await recorder.received == ["firebase:new-message", "ntfy:new-message"])
  }

  /// The reason they share a sink at all. One dead transport used to be one dead sink; now
  /// it is one provider that logged, and the others still delivered.
  @Test("A provider that throws does not stop the others")
  func oneFailureDoesNotStopTheRest() async throws {
    let recorder = Recorder()
    let sink = NotificationSink()
    await sink.attach(
      StubProvider(providerID: "firebase", failure: Boom(), recorder: recorder))
    await sink.attach(StubProvider(providerID: "ntfy", recorder: recorder))

    // Does not throw: the sink absorbs it, because the bus would otherwise treat one
    // expired FCM token as a total delivery failure.
    try await sink.deliver(event(.newMessage))
    #expect(await recorder.received == ["ntfy:new-message"])
  }

  @Test("A subscription narrows which events a provider sees")
  func subscriptionNarrows() async throws {
    let recorder = Recorder()
    let sink = NotificationSink()
    await sink.attach(
      StubProvider(
        providerID: "ntfy", subscription: .only([.newMessage]), recorder: recorder))
    await sink.attach(StubProvider(providerID: "firebase", recorder: recorder))

    try await sink.deliver(event(.newMessage))
    try await sink.deliver(event(.chatReadStatusChanged))

    #expect(
      await recorder.received == [
        "firebase:new-message", "ntfy:new-message", "firebase:chat-read-status-changed",
      ])
  }

  /// `.all` is the shipping default and must mean "whatever routing allows" — not a list
  /// someone has to keep in step with `EventName`. A new event type reaches Firebase without
  /// anyone remembering to add it, which is how it behaves today.
  @Test("The default subscription includes an event nobody enumerated")
  func allIncludesEverything() {
    #expect(EventSubscription.all.includes(.newMessage))
    #expect(EventSubscription.all.includes(EventName("an-event-invented-later")))
    #expect(!EventSubscription.only([.newMessage]).includes(.chatReadStatusChanged))
  }

  @Test("An unready provider is skipped, and the sink declines when none are ready")
  func readiness() async throws {
    let recorder = Recorder()
    let sink = NotificationSink()
    await sink.attach(
      StubProvider(providerID: "firebase", ready: false, recorder: recorder))

    #expect(await sink.accepts(event(.newMessage)) == false)
    try await sink.deliver(event(.newMessage))
    #expect(await recorder.received.isEmpty)

    await sink.attach(StubProvider(providerID: "ntfy", recorder: recorder))
    #expect(await sink.accepts(event(.newMessage)) == true)
  }

  /// Re-attaching replaces. A service that restarts would otherwise leave its old provider
  /// behind and every notification would go out twice.
  @Test("Re-attaching a provider replaces rather than duplicates")
  func attachIsIdempotent() async throws {
    let recorder = Recorder()
    let sink = NotificationSink()
    await sink.attach(StubProvider(providerID: "ntfy", recorder: recorder))
    await sink.attach(StubProvider(providerID: "ntfy", recorder: recorder))

    try await sink.deliver(event(.newMessage))
    #expect(await recorder.received == ["ntfy:new-message"])
    #expect(await sink.attachedProviderIDs == ["ntfy"])
  }

  @Test("Detaching one provider leaves the others delivering")
  func detachIsSurgical() async throws {
    let recorder = Recorder()
    let sink = NotificationSink()
    await sink.attach(StubProvider(providerID: "firebase", recorder: recorder))
    await sink.attach(StubProvider(providerID: "ntfy", recorder: recorder))
    await sink.detach(providerID: "ntfy")

    try await sink.deliver(event(.newMessage))
    #expect(await recorder.received == ["firebase:new-message"])
  }

  /// The sink routes with push, which is what moves ntfy off the webhook policy: it stops
  /// receiving typing indicators and FindMy bursts, exactly the two the reference already
  /// keeps off push.
  @Test("The sink routes as push, not as a webhook")
  func routesAsPush() {
    #expect(NotificationSink().routing == .push)
    #expect(NotificationSink().projection == .notification)
  }
}

/// Where the reference's push suppressions live now, and why ntfy is not subject to them.
///
/// They used to be applied by the bus, as `EventRouting(allowsPush: false)` on
/// `typing-indicator` and `new-findmy-location`. That read as a rule about notifications and
/// is a rule about FIREBASE — the reference delivers both to webhooks, and ntfy is a webhook
/// under v1, so moving ntfy onto push routing silently took them away from it.
///
/// `FirebaseProvider` owns the transcription now. The bus carries everything.
@Suite("Notification subscriptions")
struct NotificationSubscriptionTests {

  /// The two the reference passes `sendFcmMessage: false` for, and nothing else.
  @Test("Firebase's default declines exactly the reference's two")
  func firebaseDeclinesTheReferenceTwo() {
    let reference = EventSubscription.allExcept([.typingIndicator, .newFindMyLocation])
    #expect(!reference.includes(.typingIndicator))
    #expect(!reference.includes(.newFindMyLocation))
    for name in [
      EventName.newMessage, .updatedMessage, .chatReadStatusChanged,
      .incomingFaceTime, .iMessageAliasesRemoved,
    ] {
      #expect(reference.includes(name), "\(name) is not one the reference suppresses")
    }
  }

  /// `.allExcept` picks up an event type invented later; `.only` deliberately does not.
  @Test("allExcept admits a new event type, only does not")
  func allExceptAdmitsNewEvents() {
    let later = EventName("an-event-invented-later")
    #expect(EventSubscription.allExcept([.typingIndicator]).includes(later))
    #expect(!EventSubscription.only([.newMessage]).includes(later))
  }

  /// The point of the whole move: an ntfy topic on the default `*` receives the two events
  /// Firebase declines, which is what it received under v1 as a webhook.
  @Test("A default ntfy subscription receives what Firebase declines")
  func ntfyReceivesWhatFirebaseDeclines() async throws {
    let recorder = Recorder()
    let sink = NotificationSink()
    await sink.attach(
      StubProvider(
        providerID: "firebase",
        subscription: .allExcept([.typingIndicator, .newFindMyLocation]),
        recorder: recorder))
    await sink.attach(StubProvider(providerID: "ntfy", recorder: recorder))

    try await sink.deliver(event(.typingIndicator))
    try await sink.deliver(event(.newMessage))

    #expect(
      await recorder.received == [
        "ntfy:typing-indicator", "firebase:new-message", "ntfy:new-message",
      ])
  }
}
