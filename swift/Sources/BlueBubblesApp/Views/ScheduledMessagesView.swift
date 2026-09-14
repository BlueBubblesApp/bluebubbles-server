//  ScheduledMessagesView
//  Scheduled messages: what is queued, and a way to queue one.
//
//  Split into Upcoming and Past rather than one flat list ordered by date. The two are read
//  for different reasons: "what is about to go out" is a thing you check, "what went out" is
//  a thing you audit, and interleaving them buries the first under months of the second.
//
//  See `.claude/docs/architecture.md`.

import BBInterfaces
import BBPrivateAPICatalog
import BBSerialization
import BlueBubblesServerCore
import SwiftUI

struct ScheduledMessagesView: View {

  @Bindable var model: AppModel
  @State private var screen: ScreenModel<[ScheduledMessage]>
  @State private var isComposing = false
  /// The message Cancel was pressed for, while the confirmation is up.
  @State private var pendingCancellation: ScheduledMessage?
  /// Whether the Clear All confirmation for the Past section is up.
  @State private var isClearingPast = false

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
        // The notice on the empty page too, and above rather than beside the invitation
        // to schedule: someone who has never scheduled anything is exactly who should hear
        // about Send Later before pressing the button.
        //
        // In the same `SettingsPage` the list uses, so the notice sits in the identical
        // place whether or not there are rows, and the placeholder is simply the next
        // thing under it. Three other layouts were tried and each failed differently: a
        // `safeAreaInset` centred notice and placeholder together halfway down the page;
        // a column with the placeholder filling the rest put it far below the notice; and
        // `fixedSize(vertical: true)` on the placeholder, outside any scroll view, drew the
        // window title over the content and emptied the sidebar. That last one is the
        // failure `NoticeBody` documents at length, and a scroll view is the cure because
        // it is what proposes a width to measure against.
        SettingsPage {
          sendLaterNotice
          ContentUnavailableView {
            Label("Nothing scheduled", systemImage: "clock.badge.checkmark")
          } description: {
            Text("Schedule one here, or from a client.")
          } actions: {
            Button("Schedule a Message") { isComposing = true }
              .buttonStyle(.borderedProminent)
          }
          .frame(maxWidth: .infinity)
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
    // Confirmed, where removing ONE past row is a single click: see `row`. A failed row
    // carries the only record of why a message never went, and Clear All takes every one
    // of those at once.
    .confirmationDialog(
      "Clear \(past.count.counted("past message"))?",
      isPresented: $isClearingPast,
      titleVisibility: .visible
    ) {
      Button("Clear All", role: .destructive) { Task { await clearPast() } }
      Button("Keep Them", role: .cancel) {}
    } message: {
      Text(
        "Sent, cancelled and failed messages are removed from this list. Nothing waiting "
          + "to send is touched, and nothing in Messages is affected.")
    }
  }

  // MARK: - Send Later

  /// Which tool this Mac should be scheduling with; see `SendLaterGuidance`.
  private var guidance: SendLaterGuidance {
    SendLaterGuidance(
      macOSMajor: PrivateAPICapability.currentMacOSMajor,
      privateAPI: model.privateAPIPresence)
  }

  /// The notice that this page is the fallback, for anyone with the better option.
  ///
  /// `.informational` on purpose: it describes how two features differ. Nothing is broken
  /// on a Mac that cannot use Send Later, and an orange symbol here would say otherwise.
  private var sendLaterNotice: some View {
    NoticeCard(
      symbol: "calendar.badge.clock",
      title: guidance.title,
      messages: guidance.messages
    ) {
      if guidance.offersPrivateAPISetup {
        Button("Open Private API Settings") { model.openSettings(tab: .privateAPI) }
          .buttonStyle(.link)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: SettingsMetrics.maximumContentWidth)
  }

  private var list: some View {
    SettingsPage {
      sendLaterNotice

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
          HStack(spacing: 12) {
            Text("\(past.count)").font(.callout).foregroundStyle(.tertiary)
            Button("Clear All") { isClearingPast = true }
              .disabled(screen.isPerforming)
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
        Text(ScheduledMessageRow.text(of: message))
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Text(ScheduledMessageRow.when(message))
          if let repeats = ScheduledMessageRow.recurrence(of: message) {
            Label(repeats, systemImage: "repeat")
          }
          if let chat = ScheduledMessageRow.chat(of: message) {
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
      if ScheduledMessageRow.status(of: message) == .pending {
        // Confirmed first: the message is the person's own words, and a cancelled one is
        // gone rather than paused. See the app CLAUDE.md on destructive actions.
        Button("Cancel", role: .destructive) { pendingCancellation = message }
          .disabled(screen.isPerforming)
      } else {
        // One click, unlike Cancel: the message has already gone, or was stopped, and
        // this row is the server's record of that. Removing it changes nothing in
        // Messages and stops nothing from sending. Clear All on the section IS confirmed,
        // because it takes every failed row's error text with it in one go.
        Button("Remove") { Task { await remove(message) } }
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
    switch ScheduledMessageRow.status(of: message) {
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

  // MARK: - Reading a record
  //
  // The rules themselves are `ScheduledMessageRow`, not `private func`s here: a decision a
  // test cannot reach is a decision nothing checks, and this page's entire read of a record
  // was in that position. See that file, and `ScheduledMessageRowTests`.

  private var upcoming: [ScheduledMessage] { ScheduledMessageRow.partition(messages).upcoming }
  private var past: [ScheduledMessage] { ScheduledMessageRow.partition(messages).past }

  // MARK: - Plumbing

  /// Cancel and Remove are the same write, one row deleted. The two names are for the
  /// person: cancelling stops a send, removing tidies a record of one, and the button says
  /// which of those it is doing.
  private func cancel(_ message: ScheduledMessage) async {
    await delete(message)
  }

  private func remove(_ message: ScheduledMessage) async {
    await delete(message)
  }

  private func delete(_ message: ScheduledMessage) async {
    guard let scheduling = model.messaging.scheduling, let id = message.id
    else { return }
    await screen.perform { try await scheduling.delete(id: id) }
  }

  /// Every sent, cancelled and failed row at once. The interface leaves pending rows
  /// alone, so a recurring message between occurrences survives this.
  private func clearPast() async {
    guard let scheduling = model.messaging.scheduling else { return }
    await screen.perform { _ = try await scheduling.clearFinished() }
  }
}
