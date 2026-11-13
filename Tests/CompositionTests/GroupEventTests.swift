//  GroupEventTests
//  The six group events a group-change row announces beside its `new-message`.
//
//  They were declared, listed in the webhook catalogue and routed by every sink, and nothing
//  emitted them: a renamed group, a new member or a new group photo reached a client only as
//  a transcript line, and a webhook subscribed to `participant-added` never fired. The app
//  answers each of these by refiling the chat from `chats.first`, which is why the socket
//  payload carries the roster.
//
//  Each test drives the real builder over a fixture row rewritten into the group change
//  Messages writes, so a mapping that is right in a table and wired to nothing fails here.

import BBCore
import BBEvents
import BBIMessage
import BBSerialization
import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Group events", .removingChatDBCopies)
struct GroupEventTests {

  private func announcements(
    _ change: MessageEventFixture.GroupChange?, isNew: Bool = true,
    changedFields: Set<MessageField> = []
  ) async throws -> [ServerEvent] {
    let fixture = try await MessageEventFixture(groupChange: change)
    let row = try #require(
      try await fixture.repository.message(guid: MessageEventFixture.groupIncomingGUID))
    var hydrator = EventHydrator(repository: fixture.repository)
    return await ChangeDetectionService.announcements(
      for: MessageChange(message: row, isNew: isNew, changedFields: changedFields),
      serializer: fixture.serializer, hydrator: &hydrator
    ).map(\.event)
  }

  /// The participants of the first chat a payload names, or nil when it names none or
  /// carries no roster.
  private func participants(_ payload: JSONValue) -> [JSONValue]? {
    guard case .object(let fields) = payload, case .array(let chats) = fields["chats"],
      case .object(let chat) = chats.first, case .array(let people) = chat["participants"]
    else { return nil }
    return people
  }

  @Test(
    "Each group change announces its event, then its new-message",
    arguments: [
      (1, 0, EventName.participantAdded),
      (1, 1, .participantRemoved),
      (2, 0, .groupNameChange),
      (3, 0, .participantLeft),
      (3, 1, .groupIconChanged),
      (3, 2, .groupIconRemoved),
    ])
  func mapsEachPair(itemType: Int, groupActionType: Int, expected: EventName) async throws {
    let events = try await announcements(
      .init(
        itemType: itemType, groupActionType: groupActionType,
        title: itemType == 2 ? "Renamed" : nil))
    // Group event first: the reference emits it ahead of the message for the same row.
    #expect(events.map(\.name) == [expected, .newMessage])
    #expect(events.first?.priority == .normal, "the reference sends all six at normal")
  }

  @Test("A group-photo resend (3/3) announces a new-message and nothing else")
  func photoResendIsOnlyAMessage() async throws {
    // The row Messages writes again, under the GUID it already has, when it resends a
    // group's photo. The reference maps no event to it, and inventing one would be an event
    // a client has never been sent for this row.
    let events = try await announcements(.init(itemType: 3, groupActionType: 3))
    #expect(events.map(\.name) == [.newMessage])
  }

  @Test("An ordinary message announces no group event")
  func ordinaryMessage() async throws {
    let events = try await announcements(nil)
    #expect(events.map(\.name) == [.newMessage])
  }

  @Test("A group change is announced once, when the row arrives")
  func onlyWhenNew() async throws {
    // A read receipt moving on the row later is not a second member joining.
    let events = try await announcements(
      .init(itemType: 1, groupActionType: 0), isNew: false, changedFields: [.read])
    #expect(events.map(\.name) == [.updatedMessage])
  }

  @Test("The socket payload carries the roster; a rename's push does not")
  func projections() async throws {
    let added = try #require(
      try await announcements(.init(itemType: 1, groupActionType: 0)).first)
    #expect(added.name == .participantAdded)
    #expect(participants(added.fullPayload)?.isEmpty == false, "the socket gets the roster")
    #expect(participants(added.notificationPayload)?.isEmpty == false)

    let renamed = try #require(
      try await announcements(.init(itemType: 2, groupActionType: 0, title: "Renamed")).first)
    #expect(renamed.name == .groupNameChange)
    #expect(participants(renamed.fullPayload)?.isEmpty == false)
    #expect(
      participants(renamed.notificationPayload)?.isEmpty ?? true,
      "the reference's rename push leaves the participants out")
  }

  @Test("The six names are the ones the reference maps, and 3/3 is not among them")
  func classification() async throws {
    // The mapping on its own, so a reader sees the table without the database. A row with
    // text is never a group change.
    let fixture = try await MessageEventFixture(
      groupChange: .init(itemType: 3, groupActionType: 3))
    let resend = try #require(
      try await fixture.repository.message(guid: MessageEventFixture.groupIncomingGUID))
    #expect(ChangeDetectionService.groupEventName(for: resend) == nil)

    let withText = try #require(
      try await fixture.repository.message(guid: MessageEventFixture.incomingGUID))
    #expect(ChangeDetectionService.groupEventName(for: withText) == nil)
  }
}
