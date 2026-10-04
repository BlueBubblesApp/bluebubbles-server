//  TranscriptExportView
//  Exporting a conversation as a file, from the app.
//
//  The page a person uses who does not know a chat GUID and should not have to: pick a
//  conversation by its name, a participant's name or a number, choose a window and a
//  shape, press Export and choose where it goes. The same `TranscriptInterface` the API
//  route calls, with the same options, so the two cannot drift.
//
//  The conversation list is a `ScreenModel` read that re-runs when the server starts; the
//  run itself lives on `AppModel.transcriptExport`, which is what lets a person leave this
//  page while a long export copies its attachments and come back to find it still going.
//  Everything this page decides (the search rule, the window, the file type) is in
//  `TranscriptExportOptions.swift`, where a test can reach it.

import AppKit
import BBCore
import BBInterfaces
import BBTranscript
import BlueBubblesServerCore
import SwiftUI

struct TranscriptExportView: View {

  @Bindable var model: AppModel
  @State private var conversations: ScreenModel<[TranscriptInterface.ChatCandidate]>
  @State private var search = ""
  @State private var selectedGUID = ""
  @State private var form = TranscriptExportForm()
  @FocusState private var searchIsFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// How many conversations the picker holds. The newest first, so anything a person is
  /// likely to export is near the top; the search finds the rest.
  static let pickerLimit = 500

  init(model: AppModel) {
    self.model = model
    _conversations = State(initialValue: ScreenModel { try await Self.read(model) })
  }

  @MainActor
  private static func read(_ model: AppModel) async throws
    -> [TranscriptInterface.ChatCandidate]?
  {
    guard let interfaces = await model.messaging.interfaces() else { return nil }
    return try await interfaces.transcript.searchChats(matching: "", limit: pickerLimit)
  }

  private var candidates: [TranscriptInterface.ChatCandidate] {
    conversations.state.value ?? []
  }

  private var filtered: [TranscriptInterface.ChatCandidate] {
    TranscriptChatFilter.filter(candidates, query: search)
  }

  private var selected: TranscriptInterface.ChatCandidate? {
    candidates.first { $0.id == selectedGUID }
  }

  private var export: TranscriptExportModel { model.transcriptExport }

  var body: some View {
    Group {
      if !model.phase.isRunning {
        ServerStoppedNotice(
          model: model, placement: .page(symbol: "square.and.arrow.up"),
          purpose: "export a conversation")
      } else {
        page
      }
    }
    .reloads(conversations, following: model)
  }

  private var page: some View {
    SettingsPage {
      NoticeCard(
        symbol: "square.and.arrow.up",
        title: "Export a conversation",
        messages: [
          "Writes one conversation to a file: every message in the window you choose, "
            + "with who sent it, when, reactions, edits, and the attachments if you want "
            + "them. Names come from this Mac's contacts when it has them, and the address "
            + "is kept beside every name either way."
        ])
      conversationSection
      windowSection
      shapeSection
      runSection
    }
  }

  // MARK: - Conversation

  private var conversationSection: some View {
    SettingsSection(
      "Conversation",
      subtitle: "Search by a group's name, a contact's name, or a number."
    ) {
      searchField
      resultsList
      selectionSummary
    }
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      TextField("Search conversations", text: $search)
        .textFieldStyle(.plain)
        .focused($searchIsFocused)
        .onSubmit {
          if selectedGUID.isEmpty, let first = filtered.first { selectedGUID = first.id }
        }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }

      if !search.isEmpty {
        Button {
          search = ""
          searchIsFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
  }

  private var resultsList: some View {
    let rows = filtered
    return ScrollViewReader { proxy in
      ScrollView {
        if rows.isEmpty {
          emptyResults
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        } else {
          LazyVStack(spacing: 0) {
            ForEach(rows) { candidate in
              ConversationChoiceRow(
                candidate: candidate, isSelected: candidate.id == selectedGUID
              ) { selectedGUID = candidate.id }
              .id(candidate.id)
            }
          }
          .padding(2)
        }
      }
      .frame(height: resultsHeight(rows))
      .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
      .onChange(of: selectedGUID) { _, guid in
        guard !guid.isEmpty else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
          proxy.scrollTo(guid, anchor: .center)
        }
      }
    }
  }

  private static let rowHeight: CGFloat = 30

  /// Sized to the results, up to eight rows, so one hit is not a box of empty space.
  private func resultsHeight(_ rows: [TranscriptInterface.ChatCandidate]) -> CGFloat {
    let count = max(rows.count, 1)
    return min(CGFloat(count) * Self.rowHeight, CGFloat(8) * Self.rowHeight) + 4
  }

  @ViewBuilder
  private var emptyResults: some View {
    // Told apart by the read's own state, not by whether the value is empty: a read in
    // flight has no value yet and is not "nothing was found".
    switch conversations.state {
    case .failed(let failure):
      Label(failure, systemImage: "exclamationmark.triangle")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .idle:
      Label("Waiting for the message database.", systemImage: "clock")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .loading:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Loading conversations…")
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    case .loaded(let loaded) where loaded.isEmpty:
      Label("No conversations were found on this Mac.", systemImage: "info.circle")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .loaded:
      Label("No conversation matches “\(search)”.", systemImage: "magnifyingglass")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  /// What is chosen, kept on screen even when the search has filtered it out.
  @ViewBuilder
  private var selectionSummary: some View {
    if let selected {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
        Text(selected.chat.title)
        Text(selected.chat.participants.count.counted("participant"))
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Button("Clear") { selectedGUID = "" }
          .buttonStyle(.link)
      }
      .font(.callout)
      .lineLimit(1)
      .accessibilityElement(children: .combine)
    }
  }

  private func moveSelection(by offset: Int) -> KeyPress.Result {
    guard
      let moved = TranscriptChatFilter.selection(
        movedBy: offset, in: filtered, from: selectedGUID)
    else { return .ignored }
    selectedGUID = moved
    return .handled
  }

  // MARK: - Window

  private var windowSection: some View {
    SettingsSection(
      "Window",
      subtitle: "Leave both off for the whole conversation. Both ends are inclusive."
    ) {
      SettingsRow(title: "From", help: "The first day to include.") {
        HStack(spacing: 10) {
          Toggle("Limit the start", isOn: $form.limitsStart)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
          DatePicker("", selection: $form.start, displayedComponents: [.date])
            .labelsHidden()
            .disabled(!form.limitsStart)
        }
      }
      SettingsDivider()
      SettingsRow(title: "To", help: "The last day to include.") {
        HStack(spacing: 10) {
          Toggle("Limit the end", isOn: $form.limitsEnd)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
          DatePicker("", selection: $form.end, displayedComponents: [.date])
            .labelsHidden()
            .disabled(!form.limitsEnd)
        }
      }
    }
  }

  // MARK: - Shape

  private var shapeSection: some View {
    SettingsSection("File") {
      SettingsRow(title: "Format", help: form.format.help) {
        Picker("", selection: $form.format) {
          ForEach(TranscriptFormat.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 200)
      }
      SettingsDivider()
      SettingsRow(title: "Attachments", help: form.attachmentMode.help) {
        Picker("", selection: $form.attachmentMode) {
          ForEach(Transcript.AttachmentMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 200)
      }
      if form.attachmentMode == .files {
        SettingsDivider()
        SettingsRow(
          title: "Convert for the web",
          help: "Copies HEIC photos as JPEG and voice memos as M4A, so the page shows them "
            + "in any browser. Off keeps every file exactly as Messages stored it."
        ) {
          Toggle("Convert for the web", isOn: $form.convertAttachments)
            .labelsHidden()
            .toggleStyle(.switch)
        }
        SettingsDivider()
        SettingsRow(
          title: "Fetch from iCloud",
          help: "Asks iCloud for attachments that have been offloaded from this Mac. Needs "
            + "the Private API, and is slow per file."
        ) {
          Toggle("Fetch from iCloud", isOn: $form.downloadPurgedAttachments)
            .labelsHidden()
            .toggleStyle(.switch)
        }
      }
      SettingsDivider()
      SettingsRow(
        title: "Your name",
        help: "How your own messages are labelled in the transcript."
      ) {
        TextField("Me", text: $form.meLabel)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 200)
      }
    }
  }

  // MARK: - Running it

  private var runSection: some View {
    SettingsSection("Export") {
      switch export.phase {
      case .idle:
        readyToRun
      case .running(let summary):
        running(summary)
      case .finished(let result):
        finished(result)
      case .failed(let reason):
        VStack(alignment: .leading, spacing: 8) {
          ScreenErrorLine(message: reason)
          Button("Try Again") { export.reset() }
        }
      }
    }
  }

  @ViewBuilder
  private var readyToRun: some View {
    if let problem = form.problem {
      SettingsFootnote(text: problem, kind: .advice, tone: .warning)
    }
    HStack(spacing: 10) {
      Button("Export…") { chooseDestinationAndRun() }
        .buttonStyle(.borderedProminent)
        .disabled(selected == nil || form.problem != nil)
      if selected == nil {
        Text("Choose a conversation first.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func running(_ summary: Transcript.Summary) -> some View {
    HStack(spacing: 10) {
      ProgressView().controlSize(.small)
      VStack(alignment: .leading, spacing: 2) {
        Text("Exporting…")
        Text(Self.progressLine(summary))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Cancel") { export.cancel() }
    }
    .accessibilityElement(children: .combine)
  }

  private func finished(_ result: TranscriptInterface.ExportResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        "Exported \(result.chat.title): \(Self.progressLine(result.summary)).",
        systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
      if result.summary.attachmentsMissing > 0 {
        Text(
          "\(result.summary.attachmentsMissing.counted("attachment")) could not be found "
            + "on this Mac; the transcript says which."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      HStack(spacing: 10) {
        Button("Show in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([result.url])
        }
        Button("Export Another") { export.reset() }
      }
    }
  }

  /// "1,204 messages, 36 reactions, 12 attachments".
  static func progressLine(_ summary: Transcript.Summary) -> String {
    [
      summary.messageCount.counted("message"),
      summary.reactionCount.counted("reaction"),
      summary.attachmentCount.counted("attachment"),
    ].joined(separator: ", ")
  }

  private func chooseDestinationAndRun() {
    guard let selected else { return }
    let request = form.request(chatGUID: selected.id)
    let panel = NSSavePanel()
    panel.title = "Export Conversation"
    panel.message = "Choose where to save the transcript."
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.allowedContentTypes = [form.contentType]
    panel.nameFieldStringValue = TranscriptInterface.filename(
      for: selected.chat, request: request)
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    Task {
      guard let interfaces = await model.messaging.interfaces() else { return }
      export.start(request, to: destination, using: interfaces)
    }
  }
}

/// One conversation in the picker. Its own view for the hover state, so a row's hover is a
/// row-local fact rather than page state every keystroke invalidates.
private struct ConversationChoiceRow: View {

  let candidate: TranscriptInterface.ChatCandidate
  let isSelected: Bool
  let select: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: select) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(.tint)
          .opacity(isSelected ? 1 : 0)
          .frame(width: 12)
          .accessibilityHidden(true)
        Text(candidate.chat.title)
          .lineLimit(1)
        if let detail {
          Text(detail)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .layoutPriority(-1)
        }
        Spacer(minLength: 0)
        if candidate.isArchived {
          Tag("archived")
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 30)
      .contentShape(Rectangle())
      .background(background, in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }

  /// The address beside a one-to-one chat whose title is a name, so a person who knows the
  /// number and not the name can still tell which row this is.
  private var detail: String? {
    let participants = candidate.chat.participants
    if participants.count == 1, participants[0].name != nil {
      return participants[0].address
    }
    if candidate.chat.isGroup, candidate.chat.displayName != nil {
      return participants.count.counted("participant")
    }
    return nil
  }

  private var background: AnyShapeStyle {
    if isSelected { return AnyShapeStyle(.tint.opacity(0.18)) }
    if isHovering { return AnyShapeStyle(.quaternary.opacity(0.5)) }
    return AnyShapeStyle(.clear)
  }
}
