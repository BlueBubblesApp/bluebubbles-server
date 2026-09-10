//  ScheduledMessagesView
//  Scheduled messages: what is queued, and a way to queue one.
//
//  Split into Upcoming and Past rather than one flat list ordered by date. The two are read
//  for different reasons: "what is about to go out" is a thing you check, "what went out" is
//  a thing you audit, and interleaving them buries the first under months of the second.
//
//  See `.claude/docs/architecture.md`.

import BBInterfaces
import BBSerialization
import BlueBubblesServerCore
import SwiftUI

struct ScheduledMessagesView: View {

  @Bindable var model: AppModel
  @State private var screen: ScreenModel<[ScheduledMessage]>
  @State private var isComposing = false
  /// The message Cancel was pressed for, while the confirmation is up.
  @State private var pendingCancellation: ScheduledMessage?

  init(model: AppModel) {
    self.model = model
    _screen = State(initialValue: ScreenModel { try await Self.read(model) })
  }

  @MainActor
  private static func read(_ model: AppModel) async throws -> [ScheduledMessage]? {
    guard let scheduling = model.messaging.scheduling else { return nil }
    // Not `(try? …) ?? []`: a queue that cannot be read must not render as the "Nothing
    // scheduled" empty state, complete with a button inviting you to add to it.
    return try await scheduling.list()
  }

  private var messages: [ScheduledMessage] { screen.state.value ?? [] }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ServerStoppedNotice(
          model: model, placement: .page(symbol: "clock"), purpose: "view scheduled messages")
      } else if messages.isEmpty, screen.state.isLoading {
        // Ahead of the empty state for the same reason `problem` guards it: a queue that
        // has not been read yet also has no messages in hand, and "Nothing scheduled" with
        // a button on it is an answer nobody has established.
        LoadingNotice(subject: "scheduled messages")
      } else if messages.isEmpty, screen.problem == nil {
        // `problem == nil` guards the empty state: a queue that could not be READ also
        // has no messages, and "Nothing scheduled" over a failed read is a lie with a
        // button on it.
        ContentUnavailableView {
          Label("Nothing scheduled", systemImage: "clock.badge.checkmark")
        } description: {
          Text("Schedule one here, or from a client.")
        } actions: {
          Button("Schedule a Message") { isComposing = true }
            .buttonStyle(.borderedProminent)
        }
      } else {
        list
      }
    }
    .toolbar {
      Button {
        isComposing = true
      } label: {
        Label("Schedule a Message", systemImage: "plus")
      }
      .disabled(!model.phase.isRunning)
    }
    .sheet(isPresented: $isComposing) {
      ScheduleComposer(model: model) {
        isComposing = false
        Task { await screen.reload() }
      }
    }
    .reloads(screen, following: model)
    .confirmationDialog(
      "Cancel this scheduled message?",
      isPresented: Binding(
        get: { pendingCancellation != nil },
        set: { if !$0 { pendingCancellation = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingCancellation
    ) { message in
      Button("Cancel Message", role: .destructive) { Task { await cancel(message) } }
      Button("Keep It", role: .cancel) {}
    } message: { _ in
      Text("It will not be sent, and it is removed from this list rather than kept as a draft.")
    }
  }

  private var list: some View {
    SettingsPage {
      if let message = screen.problem {
        SettingsSection("Something went wrong") {
          SettingsFootnote(text: message, symbol: "xmark.circle", tone: .error)
            .padding(.vertical, 4)
        }
      }

      if !upcoming.isEmpty {
        SettingsSection(
          "Upcoming",
          subtitle: "Waiting to send. A recurring message stays here and moves its "
            + "date forward each time it fires."
        ) {
          ForEach(upcoming, id: \.id) { message in
            if message.id != upcoming.first?.id { SettingsDivider() }
            row(message)
          }
        } trailing: {
          Text("\(upcoming.count)").font(.callout).foregroundStyle(.tertiary)
        }
      }

      if !past.isEmpty {
        SettingsSection(
          "Past",
          subtitle: "Already sent, cancelled, or failed."
        ) {
          ForEach(past, id: \.id) { message in
            if message.id != past.first?.id { SettingsDivider() }
            row(message)
          }
        } trailing: {
          Text("\(past.count)").font(.callout).foregroundStyle(.tertiary)
        }
      }
    }
  }

  private func row(_ message: ScheduledMessage) -> some View {
    HStack(alignment: .top, spacing: 16) {
      statusIcon(message)
        .frame(width: 22)

      VStack(alignment: .leading, spacing: 5) {
        Text(text(message))
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Text(when(message))
          if let repeats = recurrence(message) {
            Label(repeats, systemImage: "repeat")
          }
          if let chat = chat(message) {
            Label(chat, systemImage: "bubble.left.and.bubble.right")
          }
        }
        .font(.callout)
        .foregroundStyle(.secondary)

        if let failure = message.error, !failure.isEmpty {
          SettingsFootnote(text: failure, symbol: "xmark.circle", tone: .error)
        }
      }

      Spacer(minLength: 12)

      // Only a pending message can be cancelled. One already sent cannot be unsent,
      // and offering the button would be a lie.
      if Self.status(of: message) == .pending {
        // Confirmed first: the message is the person's own words, and a cancelled one is
        // gone rather than paused. See the app CLAUDE.md on destructive actions.
        Button("Cancel", role: .destructive) { pendingCancellation = message }
          .disabled(screen.isPerforming)
      }
    }
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
  }

  @ViewBuilder
  private func statusIcon(_ message: ScheduledMessage) -> some View {
    // The declared cases, not their spellings. `ScheduledMessageStatus` is right here in
    // `BBInterfaces` and this file already used it for `.pending`; the other three were
    // string literals, so a renamed case would have rendered as the fallback clock with
    // nothing failing. A status this build does not know gets the clock too, which is the
    // honest answer for "queued, state unrecognised".
    switch Self.status(of: message) {
    case .sent:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
    case .cancelled:
      Image(systemName: "slash.circle").foregroundStyle(.secondary)
    case .pending, nil:
      Image(systemName: "clock").foregroundStyle(.tint)
    }
  }

  private static func status(of message: ScheduledMessage) -> ScheduledMessageStatus? {
    ScheduledMessageStatus(rawValue: message.status)
  }

  // MARK: - Reading a record

  private var upcoming: [ScheduledMessage] {
    messages.filter { Self.status(of: $0) == .pending }
  }
  private var past: [ScheduledMessage] {
    messages.filter { Self.status(of: $0) != .pending }
  }

  /// `payload` and `schedule` stay JSON because they genuinely are: both are opaque client
  /// blobs the server stores and never parses. Everything else on the row (status, error,
  /// the date) is a real column and is read as one.
  private func payload(_ message: ScheduledMessage) -> JSONValue? {
    try? JSONValue.parse(message.payload)
  }

  private func text(_ message: ScheduledMessage) -> String {
    let body = payload(message)?["message"]?.stringValue ?? ""
    return body.isEmpty ? "(no message text)" : body
  }

  private func chat(_ message: ScheduledMessage) -> String? {
    guard let guid = payload(message)?["chatGuid"]?.stringValue, !guid.isEmpty
    else { return nil }
    // The address is the readable half; the service prefix is noise in a list.
    return guid.components(separatedBy: ";-;").last ?? guid
  }

  /// How often it repeats, in the words the composer's own picker used.
  ///
  /// Read back through `ScheduleRecurrence`, so a row says "daily" or "every 3 days". It
  /// rendered the stored WIRE value instead ("every 2 × daily") because the type that
  /// knows the vocabulary was private to the composer.
  private func recurrence(_ message: ScheduledMessage) -> String? {
    guard let raw = message.schedule,
      let schedule = try? JSONValue.parse(raw),
      schedule["type"]?.stringValue == "recurring",
      let interval = schedule["intervalType"]?.stringValue,
      let recurrence = ScheduleRecurrence(intervalType: interval)
    else { return nil }
    return recurrence.summary(every: schedule["interval"]?.intValue ?? 1)
  }

  private func when(_ message: ScheduledMessage) -> String {
    // A `Date` column read as a `Date`, not formatted to an ISO string in the interface
    // and parsed back here, and not read as epoch milliseconds, which the wire rule
    // elsewhere would suggest and which silently shows an em dash for every scheduled
    // message.
    let date = message.scheduledFor
    // Relative for anything close, absolute otherwise: "in 20 minutes" is what you want
    // for something imminent and useless for something three months old.
    if abs(date.timeIntervalSinceNow) < 60 * 60 * 18 {
      return date.formatted(.relative(presentation: .named))
    }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  // MARK: - Plumbing

  private func cancel(_ message: ScheduledMessage) async {
    guard let scheduling = model.messaging.scheduling, let id = message.id
    else { return }
    await screen.perform { try await scheduling.delete(id: id) }
  }
}
