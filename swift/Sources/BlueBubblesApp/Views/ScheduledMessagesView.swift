//  ScheduledMessagesView
//  Scheduled messages: what is queued, and a way to queue one.
//
//  The page was read-only, which made it the one place in the app that could show you
//  something and not let you make one. The Electron server had a full composer here; the API
//  underneath has had `create` all along, so this was a missing screen rather than a missing
//  feature.
//
//  Split into Upcoming and Past rather than one flat list ordered by date. The two are read
//  for different reasons — "what is about to go out" is a thing you check, "what went out" is
//  a thing you audit — and interleaving them buries the first under months of the second.
//
//  See `.claude/docs/architecture.md`.

import BBHandlers
import BBInterfaces
import BBSerialization
import BlueBubblesServerCore
import SwiftUI

struct ScheduledMessagesView: View {

  @Bindable var model: AppModel
  @State private var screen: ScreenModel<[ScheduledMessage]>
  @State private var isComposing = false

  init(model: AppModel) {
    self.model = model
    _screen = State(initialValue: ScreenModel { try await Self.read(model) })
  }

  @MainActor
  private static func read(_ model: AppModel) async throws -> [ScheduledMessage]? {
    guard let scheduling = model.scheduling else { return nil }
    // Was `(try? …) ?? []`, which rendered a queue that could not be read as the
    // "Nothing scheduled" empty state — complete with a button inviting you to add to it.
    return try await scheduling.records()
  }

  private var messages: [ScheduledMessage] { screen.state.value ?? [] }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ContentUnavailableView(
          "Server not running",
          systemImage: "clock",
          description: Text("Start the server to view scheduled messages.")
        )
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
    .task { await screen.reload() }
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
            + "date forward each time it fires.",
          trailing: AnyView(
            Text("\(upcoming.count)").font(.callout).foregroundStyle(.tertiary)
          )
        ) {
          ForEach(Array(upcoming.enumerated()), id: \.offset) { index, message in
            if index > 0 { SettingsDivider() }
            row(message)
          }
        }
      }

      if !past.isEmpty {
        SettingsSection(
          "Past",
          subtitle: "Already sent, cancelled, or failed.",
          trailing: AnyView(
            Text("\(past.count)").font(.callout).foregroundStyle(.tertiary)
          )
        ) {
          ForEach(Array(past.enumerated()), id: \.offset) { index, message in
            if index > 0 { SettingsDivider() }
            row(message)
          }
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
      if message.status == ScheduledMessageStatus.pending.rawValue {
        Button("Cancel", role: .destructive) { Task { await cancel(message) } }
      }
    }
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
  }

  @ViewBuilder
  private func statusIcon(_ message: ScheduledMessage) -> some View {
    switch message.status {
    case "sent":
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case "failed":
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
    case "cancelled":
      Image(systemName: "slash.circle").foregroundStyle(.secondary)
    default:
      Image(systemName: "clock").foregroundStyle(.tint)
    }
  }

  // MARK: - Reading a record

  private var upcoming: [ScheduledMessage] {
    messages.filter { $0.status == ScheduledMessageStatus.pending.rawValue }
  }
  private var past: [ScheduledMessage] {
    messages.filter { $0.status != ScheduledMessageStatus.pending.rawValue }
  }

  /// `payload` and `schedule` stay JSON because they genuinely are: both are opaque client
  /// blobs the server stores and never parses. Everything else on the row — status, error,
  /// the date — is a real column and is read as one.
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

  private func recurrence(_ message: ScheduledMessage) -> String? {
    guard let raw = message.schedule,
      let schedule = try? JSONValue.parse(raw),
      schedule["type"]?.stringValue == "recurring",
      let interval = schedule["intervalType"]?.stringValue
    else { return nil }
    let every = schedule["interval"]?.intValue ?? 1
    return every > 1 ? "every \(every) × \(interval)" : interval
  }

  private func when(_ message: ScheduledMessage) -> String {
    // A `Date` column read as a `Date` — not formatted to an ISO string in the interface
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
    guard let scheduling = model.scheduling, let id = message.id
    else { return }
    await screen.perform { try await scheduling.delete(id: id) }
  }
}
