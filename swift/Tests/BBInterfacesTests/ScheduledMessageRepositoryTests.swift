//  ScheduledMessageRepositoryTests
//  Clearing the history must not touch anything still waiting to send.
//
//  `deleteFinished` is keyed on NOT pending so a status added later is cleared too, which
//  makes the pending row the one thing to prove about it: a recurring message between
//  occurrences is `pending` with a `sent_at`, and looks finished to a query that checks the
//  wrong column.

import BBPersistence
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Scheduled message repository")
struct ScheduledMessageRepositoryTests {

  private func record(status: ScheduledMessageStatus, sentAt: Date? = nil) -> ScheduledMessage {
    ScheduledMessage(
      id: nil,
      type: "send-message",
      payload: Data(#"{"chatGuid":"iMessage;-;+15555550101","message":"hi"}"#.utf8),
      scheduledFor: Date(timeIntervalSince1970: 1_700_000_000),
      schedule: nil,
      status: status.rawValue,
      error: nil,
      sentAt: sentAt,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000)
    )
  }

  @Test("Clearing finished messages keeps every pending one and reports the count")
  func clearFinishedKeepsPending() async throws {
    let store = ScheduledMessageRepository(
      database: try AppDatabase.inMemory(contributors: [InterfacesSchema.self]))
    for status in ScheduledMessageStatus.allCases {
      _ = try await store.insert(record(status: status))
    }
    // A recurring message that has fired once: still pending, but with a send on record.
    _ = try await store.insert(record(status: .pending, sentAt: Date()))

    let removed = try await store.deleteFinished()

    #expect(removed == ScheduledMessageStatus.allCases.count - 1)
    let remaining = try await store.all()
    #expect(remaining.count == 2)
    #expect(remaining.allSatisfy { $0.status == ScheduledMessageStatus.pending.rawValue })
  }

  /// A message is taken out of the due set BEFORE it is sent, so an interrupted send cannot
  /// be sent again.
  ///
  /// The sweep recorded the outcome only AFTER `perform`, so a crash, an out-of-memory kill
  /// or a `replaceProcess()` mid-send left the row exactly as it was and the next tick sent
  /// the same message to a real person a second time. The comment on the sweep described
  /// this ordering for months without it being implemented.
  ///
  /// The trade is deliberate: a send interrupted after the claim is NOT retried. Sending
  /// twice is visible to the recipient and cannot be taken back; not sending is visible to
  /// the sender, who still has the text.
  @Test("A claimed one-shot message is no longer due")
  func claimingRemovesAOneShotFromTheDueSet() async throws {
    let store = ScheduledMessageRepository(
      database: try AppDatabase.inMemory(contributors: [InterfacesSchema.self]))
    let stored = try await store.insert(record(status: .pending))
    let now = Date(timeIntervalSince1970: 1_700_000_100)

    #expect(try await store.due(at: now).count == 1, "it should start out due")

    try await store.claimForDispatch(id: stored.id!, nextOccurrence: nil, at: now)

    // This is the crash window: the process dies here, between the claim and the outcome.
    #expect(
      try await store.due(at: now).isEmpty,
      "an interrupted send must not leave the message due for the next sweep"
    )
  }

  @Test("A claimed recurring message moves to its next occurrence, not out of the list")
  func claimingARecurringMessageMovesItOn() async throws {
    // A recurring message stays pending; what must change is WHEN. Moving it out entirely
    // would silently end the series after its first send.
    let store = ScheduledMessageRepository(
      database: try AppDatabase.inMemory(contributors: [InterfacesSchema.self]))
    let stored = try await store.insert(record(status: .pending))
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let next = now.addingTimeInterval(86_400)

    try await store.claimForDispatch(id: stored.id!, nextOccurrence: next, at: now)

    #expect(try await store.due(at: now).isEmpty, "not due again today")
    let read = try #require(try await store.find(id: stored.id!))
    #expect(read.status == ScheduledMessageStatus.pending.rawValue, "the series continues")
    #expect(read.scheduledFor == next)
    #expect(try await store.due(at: next).count == 1, "and it is due again tomorrow")
  }

  @Test("A send that fails afterwards is still recorded as failed")
  func aFailureAfterTheClaimIsRecorded() async throws {
    // The claim is provisional. `recordOutcome` corrects it, including back to `failed`,
    // so a one-shot that threw does not sit there reading as sent.
    let store = ScheduledMessageRepository(
      database: try AppDatabase.inMemory(contributors: [InterfacesSchema.self]))
    let stored = try await store.insert(record(status: .pending))
    let now = Date(timeIntervalSince1970: 1_700_000_100)

    try await store.claimForDispatch(id: stored.id!, nextOccurrence: nil, at: now)
    try await store.recordOutcome(
      id: stored.id!, nextOccurrence: nil, outcome: .failed, failure: "Messages said no",
      at: now)

    let read = try #require(try await store.find(id: stored.id!))
    #expect(read.status == ScheduledMessageStatus.failed.rawValue)
    #expect(read.error == "Messages said no")
    // And it does not come back: a failed send is reported, not retried forever.
    #expect(try await store.due(at: now).isEmpty)
  }

  /// The failure this whole branch exists for, and the one it used to cause.
  ///
  /// `recordOutcome` keyed the recurring branch on `outcome == .sent`, so a recurring row
  /// whose send threw fell through to the terminal branch and was written `failed`. Nothing
  /// picked it up again: one transient refusal from Messages permanently ended a daily
  /// reminder, and the only trace was a status nobody has reason to look at.
  @Test("A failed send does not end a recurring series")
  func aFailureDoesNotEndTheSeries() async throws {
    let store = ScheduledMessageRepository(
      database: try AppDatabase.inMemory(contributors: [InterfacesSchema.self]))
    let stored = try await store.insert(record(status: .pending))
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let next = now.addingTimeInterval(86_400)

    try await store.claimForDispatch(id: stored.id!, nextOccurrence: next, at: now)
    try await store.recordOutcome(
      id: stored.id!, nextOccurrence: next, outcome: .failed, failure: "Messages said no",
      at: now)

    let read = try #require(try await store.find(id: stored.id!))
    #expect(
      read.status == ScheduledMessageStatus.pending.rawValue,
      "a recurring series must survive one failed send")
    #expect(read.scheduledFor == next, "and it must have moved to the next occurrence")
    #expect(read.error == "Messages said no", "while still recording why this one failed")
    #expect(try await store.due(at: next).count == 1, "so the next tick picks it up")
  }

  @Test("The series anchor is stored and read back, and stays off the wire")
  func anchorRoundTrips() async throws {
    let store = ScheduledMessageRepository(
      database: try AppDatabase.inMemory(contributors: [InterfacesSchema.self]))
    var row = record(status: .pending)
    row.firstScheduledFor = Date(timeIntervalSince1970: 1_690_000_000)
    let stored = try await store.insert(row)

    let read = try await store.find(id: stored.id!)
    #expect(read?.firstScheduledFor == row.firstScheduledFor)
    // The v1 projection is frozen; a new column must not become a new key.
    #expect(stored.json["firstScheduledFor"] == nil)
    #expect(stored.json["first_scheduled_for"] == nil)
  }
}
