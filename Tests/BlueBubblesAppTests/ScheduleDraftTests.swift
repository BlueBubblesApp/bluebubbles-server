//  ScheduleDraftTests
//  What the schedule sheet sends, and when it lets you send it.
//
//  A scheduled message that is aimed wrong fails hours later, with nobody watching. These
//  are the rules that decide where it is aimed and what it carries.

import BBAppStore
import BBCore
import BBInterfaces
import BBPersistence
import BlueBubblesServerCore
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Schedule draft")
struct ScheduleDraftTests {

  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("A new draft is aimed fifteen minutes out, never at a time already past")
  func defaultSendTime() {
    let draft = ScheduleDraft(now: Self.now)
    #expect(draft.sendAt == Self.now.addingTimeInterval(900))
    #expect(draft.recipient == .existingChat)
    #expect(draft.repeats == .never)
    #expect(draft.every == 1)
  }

  @Test("Save needs words and somewhere to send them")
  func canSave() {
    var draft = ScheduleDraft(now: Self.now)
    #expect(!draft.canSave)
    draft.message = "   "
    draft.selectedChatGUID = "any;-;someone@example.com"
    #expect(!draft.canSave, "whitespace is not a message")
    draft.message = "BB test"
    #expect(draft.canSave)

    // The other recipient kind reads the other field.
    draft.recipient = .address
    #expect(!draft.canSave)
    draft.address = " +12025550143 "
    #expect(draft.canSave)
  }

  @Test("The target is the chosen chat, or the GUID a typed address becomes")
  func target() {
    var draft = ScheduleDraft(now: Self.now)
    draft.selectedChatGUID = "any;+;chat000000000000000001"
    draft.address = " someone@example.com "
    #expect(draft.targetGUID == "any;+;chat000000000000000001")

    draft.recipient = .address
    draft.service = "SMS"
    #expect(draft.hasAddress)
    #expect(draft.composedGUID == "SMS;-;someone@example.com")
    #expect(draft.targetGUID == "SMS;-;someone@example.com")
  }

  @Test("The interval is clamped as it is written, so what is sent is what was shown")
  func intervalClamp() {
    var draft = ScheduleDraft(now: Self.now)
    draft.every = 0
    #expect(draft.every == 1)
    draft.every = -4
    #expect(draft.every == 1)
    draft.every = 500
    #expect(draft.every == 52)
    draft.every = 3
    #expect(draft.every == 3)
  }

  @Test("A one-off message carries no schedule")
  func oneOffRequest() {
    var draft = ScheduleDraft(now: Self.now)
    draft.selectedChatGUID = "any;-;someone@example.com"
    draft.message = "BB test"
    #expect(
      draft.request
        == ScheduleInterface.NewMessage(
          type: "send-message",
          payload: .init(
            chatGUID: "any;-;someone@example.com", message: "BB test", method: .appleScript),
          scheduledFor: draft.sendAt,
          schedule: nil
        ))
  }

  @Test("A recurring message carries its wire interval type and interval")
  func recurringRequest() {
    var draft = ScheduleDraft(now: Self.now)
    draft.selectedChatGUID = "any;-;someone@example.com"
    draft.message = "BB test"
    draft.repeats = .weekly
    draft.every = 2
    #expect(
      draft.request.schedule == ScheduleInterface.Recurrence(intervalType: "weekly", interval: 2))
  }

  /// The sheet's request is accepted by the interface it is for. It was not: the payload
  /// named no `method`, which the interface requires, so every save from the sheet was
  /// refused with "Missing required payload fields: method".
  @Test("What the sheet sends is what the interface accepts")
  func requestIsAccepted() async throws {
    var draft = ScheduleDraft(now: Date())
    draft.selectedChatGUID = "any;-;someone@example.com"
    draft.message = "BB test"
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let stored = try await ScheduleInterface(database: database).create(draft.request)
    #expect(stored.status == ScheduledMessageStatus.pending.rawValue)
  }
}
