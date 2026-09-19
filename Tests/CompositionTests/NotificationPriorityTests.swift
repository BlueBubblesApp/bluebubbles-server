//  NotificationPriorityTests
//  Which push notifications are sent at FCM high priority.
//
//  Not cosmetic, and invisible to every other test here. A `normal`-priority FCM data message
//  is DEFERRED by Android under Doze and App Standby, so an incoming iMessage can arrive
//  minutes late on a phone that has been idle — while the payload, the event name and the
//  socket delivery are all exactly right. Nothing in the parity harness inspects a push
//  payload, so the only thing standing between this and a silent regression is an assertion.
//
//  Every event this builder produced defaulted to `.normal`, which made late notifications the
//  behaviour for every message the server sends.
//
//  The reference, which is the contract here: `electron/packages/server/src/server/index.ts:1556` emits
//  NEW_MESSAGE at `newMessage.isFromMe ? "normal" : "high"`. Every other emit in that file
//  passes the literal `"normal"` — MESSAGE_UPDATED at `:1602`, and the six group events at
//  `:1365`-`:1510`.

import BBEvents
import BBIMessage
import BBPersistence
import BBSerialization
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Notification priority")
struct NotificationPriorityTests {

  /// The builder's answer, both halves of it.
  ///
  /// Returns the NAME as well as the priority, and that is the point of this rewrite. The
  /// `.messageSendError` branch needs `error != 0` and no fixture row has one, so the send
  /// error test below was getting an ordinary `.updatedMessage` back — and asserting
  /// `.normal`, which an update is too. It passed for years without once reaching the branch
  /// it is named after. Asserting the name is what makes the priority assertion mean
  /// something; see `MessageEventFixture`.
  private func event(
    guid: String,
    isNew: Bool,
    changedFields: Set<MessageField> = [],
    failing: Bool = false
  ) async throws -> (name: EventName, priority: EventPriority) {
    let fixture = try await MessageEventFixture(
      named: "priority", failing: failing ? guid : nil)
    let row = try #require(
      try await fixture.repository.message(guid: guid),
      "the fixture should hold \(guid)")
    var hydrator = EventHydrator(repository: fixture.repository)
    let event = try #require(
      await ChangeDetectionService.event(
        for: MessageChange(message: row, isNew: isNew, changedFields: changedFields),
        serializer: fixture.serializer,
        hydrator: &hydrator
      ))
    return (event.name, event.priority)
  }

  @Test("A new message from someone else is high priority")
  func incomingIsHigh() async throws {
    // The one case the reference sends at high, and the one that decides whether a person
    // sees a message when it arrives or when their phone next wakes up.
    let event = try await event(guid: MessageEventFixture.incomingGUID, isNew: true)
    #expect(event.name == .newMessage)
    #expect(event.priority == .high)
  }

  @Test("A new message the user sent themselves is normal priority")
  func outgoingIsNormal() async throws {
    // Already on the screen of the device that sent it, so waking every other device for it
    // buys nothing. This is the half `isFromMe` exists for, and sending everything at high
    // would be just as wrong as sending everything at normal — it spends the high-priority
    // budget Android and FCM both meter.
    let event = try await event(guid: MessageEventFixture.outgoingGUID, isNew: true)
    #expect(event.name == .newMessage)
    #expect(event.priority == .normal)
  }

  @Test("An update to an existing message is normal priority")
  func updateIsNormal() async throws {
    // A read receipt, an edit, an unsend. The reference passes the literal "normal" for
    // MESSAGE_UPDATED regardless of who sent the message, so an incoming message being
    // marked read must not inherit the high priority its arrival had.
    let event = try await event(
      guid: MessageEventFixture.incomingGUID, isNew: false, changedFields: [.read])
    #expect(event.name == .updatedMessage)
    #expect(event.priority == .normal)
  }

  @Test("A send error is normal priority")
  func sendErrorIsNormal() async throws {
    // Its own event name, but still a report about the user's own outgoing message, and the
    // reference has no high-priority emit for it.
    // `failing: true`, without which this never reaches the send-error branch at all —
    // the builder requires a non-zero `error` column as well as the changed field, and the
    // fixture has none. The name assertion is what proves it now does.
    let event = try await event(
      guid: MessageEventFixture.outgoingGUID, isNew: false, changedFields: [.error],
      failing: true)
    #expect(event.name == .messageSendError, "the send-error branch must actually be reached")
    #expect(event.priority == .normal)
  }
}
