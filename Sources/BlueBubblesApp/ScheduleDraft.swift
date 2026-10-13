//  ScheduleDraft
//  What the schedule sheet is filling in, and what Save does with it.
//
//  The sheet held this as nine separate `@State` values beside the six that are the sheet's
//  own business (the conversation list, the search, a save in flight), and the decisions over
//  them (whether the form is complete, which GUID it is aimed at, what the request carries,
//  how far a recurrence may skip) were private to the view, where a test cannot reach them.
//  A message scheduled wrong is found out hours later, at send time, with the person who
//  scheduled it gone: those rules are the ones that most need asserting.
//
//  So the form is one value, and the view binds into it and decides nothing. See
//  `ScheduleDraftTests`.

import BBCore
import BBInterfaces
import Foundation

struct ScheduleDraft: Equatable {

  /// Who the message goes to. The case is the identity; `title` is what the picker shows.
  enum Recipient: CaseIterable, Identifiable, Hashable {
    case existingChat, address
    var id: Self { self }
    var title: String {
      switch self {
      case .existingChat: "A conversation"
      case .address: "An address"
      }
    }
  }

  /// How many periods a recurrence may skip. Weekly at 52 is a year, which is as far as the
  /// control needs to reach.
  static let intervalRange = 1...52

  /// How far ahead a new draft's send time starts. A default of "right now" is already in the
  /// past by the time the sheet is filled in, and `create` rejects a past time rather than
  /// sending immediately.
  static let defaultLead: TimeInterval = 900

  var recipient: Recipient = .existingChat
  /// The conversation picked from the list, or empty. Used when `recipient` is
  /// `.existingChat`.
  var selectedChatGUID = ""
  /// A typed address, and the service to reach it on. Used when `recipient` is `.address`.
  var address = ""
  var service = "iMessage"
  var message = ""
  var sendAt: Date
  var repeats: ScheduleRecurrence = .never
  /// Clamped into `intervalRange` as it is written. The stepper is bounded and the text field
  /// beside it is not, so a 0 or a negative could be typed and was quietly turned into 1 at
  /// save time: the value sent was not the value on screen.
  var every = 1 {
    didSet {
      let clamped = min(max(every, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
      if clamped != every { every = clamped }
    }
  }

  init(now: Date = Date()) {
    sendAt = now.addingTimeInterval(Self.defaultLead)
  }

  /// The GUID a typed address becomes. Shown on the sheet rather than assembled invisibly:
  /// if this is wrong it fails at send time, and the person is not there to see it.
  ///
  /// Built through `ChatGUID`, the one place that knows the shape, and with the service the
  /// person chose. A constructed GUID is safe to aim at whichever prefix the Mac's own rows
  /// carry (`any` on macOS 26 and later): every lookup goes through
  /// `ChatGUID.lookupCandidates`, which ignores the prefix.
  var composedGUID: String {
    ChatGUID(
      servicePrefix: service, separator: .direct,
      address: address.trimmingCharacters(in: .whitespaces)
    ).description
  }

  /// Whether there is a typed address to show `composedGUID` for.
  var hasAddress: Bool { !address.trimmingCharacters(in: .whitespaces).isEmpty }

  /// The chat the message is aimed at, whichever way it was chosen.
  var targetGUID: String {
    recipient == .existingChat ? selectedChatGUID : composedGUID
  }

  /// Whether Save can be pressed: there is something to say and somewhere to send it.
  var canSave: Bool {
    let destination = recipient == .existingChat ? selectedChatGUID : address
    return !message.trimmingCharacters(in: .whitespaces).isEmpty
      && !destination.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// What `ScheduleInterface.create` is asked to store: the same record a client's
  /// `POST /api/v1/message/schedule` becomes, so the sheet and a client schedule the same way.
  ///
  /// `method` is AppleScript, which is what the reference defaults a send to when none is
  /// named (`messageValidator.ts:89-90`). The payload has to name one, because the
  /// reference's validator requires it (`scheduledMessageValidator.ts:26-30`) and so does
  /// `ScheduleInterface`, and the sheet offers no choice of backend.
  var request: ScheduleInterface.NewMessage {
    ScheduleInterface.NewMessage(
      payload: .init(chatGUID: targetGUID, message: message, method: .appleScript),
      scheduledFor: sendAt,
      schedule: repeats.intervalType.map {
        ScheduleInterface.Recurrence(intervalType: $0, interval: max(1, every))
      }
    )
  }
}
