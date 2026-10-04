//  ScheduleComposer
//  Creating a scheduled message.
//
//  The recipient is chosen from EXISTING chats rather than typed as a GUID. A chat GUID is
//  `iMessage;-;+15550101234` and getting the service prefix wrong produces a message that
//  fails at send time, hours later, with the user long gone. Picking from chats that already
//  exist means the GUID is never assembled by hand.
//
//  There is still an escape hatch for an address with no chat yet, because refusing that case
//  would make the composer unable to do something the API can. It says plainly what it will
//  build, so a failure is at least predictable.
//
//  The conversation is chosen with `ConversationPicker`, the one picker every page uses, in
//  single mode: a contact name where the address book has one, the formatted number where it
//  does not, and the address beside the name on a one-to-one chat, exactly as the export page
//  and the webhook filter show the same chat.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import BBSerialization
import BlueBubblesServerCore
import SwiftUI

struct ScheduleComposer: View {

  @Bindable var model: AppModel
  let onDone: () -> Void

  init(model: AppModel, onDone: @escaping () -> Void) {
    self.model = model
    self.onDone = onDone
  }

  @Environment(\.dismiss) private var dismiss

  private enum Recipient: CaseIterable, Identifiable {
    case existingChat, address
    var id: Self { self }
    var title: String {
      switch self {
      case .existingChat: "A conversation"
      case .address: "An address"
      }
    }
  }

  @State private var recipient: Recipient = .existingChat
  /// The chosen conversation, as the picker holds it: zero or one GUID.
  @State private var chosenChats: Set<String> = []
  @State private var address = ""
  @State private var service = "iMessage"
  @State private var messageBody = ""
  // Fifteen minutes out. A default of "right now" is already in the past by the time the
  // sheet is filled in, and `create` rejects a past time rather than sending immediately.
  @State private var sendAt = Date().addingTimeInterval(900)
  @State private var repeats: ScheduleRecurrence = .never
  @State private var every = 1
  @State private var isSaving = false
  @State private var error: String?

  /// How many periods a recurrence may skip. Weekly at 52 is a year, which is as far as
  /// this control needs to reach.
  private static let intervalRange = 1...52

  var body: some View {
    SheetScaffold(
      title: "Schedule a Message",
      subtitle: "It is stored on the server and sent even if this window is closed.",
      confirmTitle: "Schedule",
      isConfirmEnabled: canSave && !isSaving,
      error: error,
      confirm: { await save() }
    ) {
      recipientSection
      messageSection
      timingSection
    }
  }

  // MARK: - Sections

  private var recipientSection: some View {
    SettingsSection("Send to") {
      SettingsRow(title: "Recipient") {
        Picker("", selection: $recipient) {
          ForEach(Recipient.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }

      SettingsDivider()

      if recipient == .existingChat {
        SettingsWideRow(
          title: "Conversation",
          help: "Only conversations that already exist. Start a new one in Messages "
            + "first, or send to an address below."
        ) {
          ConversationPicker(model: model, selection: $chosenChats, mode: .single)
        }
      } else {
        SettingsRow(title: "Address", help: "A phone number or email address.") {
          TextField("+15550101234", text: $address)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
        }
        SettingsDivider()
        SettingsRow(title: "Service") {
          Picker("", selection: $service) {
            Text("iMessage").tag("iMessage")
            Text("SMS").tag("SMS")
          }
          .labelsHidden()
          .controlSize(.large)
          .frame(maxWidth: 200)
        }
        if !address.trimmingCharacters(in: .whitespaces).isEmpty {
          SettingsDivider()
          // Shown rather than assembled invisibly: if this is wrong, it fails at
          // send time and the user is not there to see it.
          SettingsRow(title: "Will send to") {
            Text(composedGUID)
              .font(.system(.callout, design: .monospaced))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }
    }
  }

  private var messageSection: some View {
    SettingsSection("Message") {
      SettingsWideRow(title: "Text") {
        TextEditor(text: $messageBody)
          .font(.body)
          .frame(minHeight: 110)
          .scrollContentBackground(.hidden)
          .padding(6)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private var timingSection: some View {
    SettingsSection("When") {
      SettingsRow(
        title: "Send at",
        help: "Must be in the future; the server rejects a past time rather than "
          + "sending immediately."
      ) {
        // Bounded at now, so a past time cannot be chosen at all. The server refuses one,
        // and finding that out when the Schedule button reports it is finding out late.
        DatePicker(
          "", selection: $sendAt, in: Date()...,
          displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        .controlSize(.large)
      }

      SettingsDivider()

      SettingsRow(title: "Repeat") {
        Picker("", selection: $repeats) {
          ForEach(ScheduleRecurrence.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .controlSize(.large)
        .frame(maxWidth: 200)
      }

      if repeats != .never {
        SettingsDivider()
        SettingsRow(
          title: "Every",
          help: "How many \(repeats.period.map { $0 + "s" } ?? "periods") between sends."
        ) {
          HStack(spacing: 8) {
            Spacer(minLength: 0)
            TextField("", value: $every, format: .number)
              .textFieldStyle(.roundedBorder)
              .controlSize(.large)
              .frame(width: 90)
              // Clamped as typed. The stepper is bounded and the field was not, so a 0 or
              // a negative could be typed into it and was quietly turned into 1 at save
              // time: the value sent was not the value on screen.
              .onChange(of: every) { _, new in
                let range = Self.intervalRange
                let clamped = min(max(new, range.lowerBound), range.upperBound)
                if clamped != new { every = clamped }
              }
            Stepper("", value: $every, in: Self.intervalRange).labelsHidden()
          }
        }
        SettingsDivider()
        // Calendar months and years, and the one edge that has: a date not every month
        // has. Said where the interval is chosen, so the 31st is picked knowing what
        // February does with it.
        SettingsFootnote(text: repeatNote, symbol: "info.circle")
          .padding(.vertical, 4)
      }
    }
  }

  private var repeatNote: String {
    switch repeats {
    case .monthly:
      "Repeats on this day each month until you cancel it. A month without this day "
        + "sends on its last day instead."
    case .yearly:
      "Repeats on this date each year until you cancel it. February 29 sends on "
        + "February 28 in other years."
    default: "Repeats until you cancel it."
    }
  }

  // MARK: - Saving

  private var composedGUID: String {
    "\(service);-;\(address.trimmingCharacters(in: .whitespaces))"
  }

  private var targetGUID: String {
    recipient == .existingChat ? (chosenChats.first ?? "") : composedGUID
  }

  private var canSave: Bool {
    !messageBody.trimmingCharacters(in: .whitespaces).isEmpty
      && !(recipient == .existingChat ? (chosenChats.first ?? "") : address)
        .trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func save() async {
    // Scheduling touches only the app database: the chat.db gate belongs on the picker,
    // which is what actually reads conversations.
    guard let scheduling = model.messaging.scheduling else { return }
    isSaving = true
    defer { isSaving = false }
    error = nil

    var payload = JSONObjectBuilder()
    payload.set("chatGuid", .string(targetGUID))
    payload.set("message", .string(messageBody))

    var request = JSONObjectBuilder()
    request.set("type", .string("send-message"))
    request.set("payload", payload.build())
    request.set("scheduledFor", .int64(Int64(sendAt.timeIntervalSince1970 * 1000)))
    if let intervalType = repeats.intervalType {
      request.set(
        "schedule",
        .object([
          "type": .string("recurring"),
          "intervalType": .string(intervalType),
          "interval": .int64(Int64(max(1, every))),
        ]))
    }

    do {
      _ = try await scheduling.create(request.build())
      onDone()
      dismiss()
    } catch {
      // The server's own words. "`scheduledFor` is in the past" tells someone exactly
      // what to change; "could not schedule" sends them guessing.
      self.error = DiagnosticText.sentence(for: error)
    }
  }
}
