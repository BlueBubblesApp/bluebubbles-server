//  TranscriptExportView
//  Exporting a conversation as a file, from the app.
//
//  The page a person uses who does not know a chat GUID and should not have to: pick a
//  conversation by its name, a participant's name or a number, choose a window and a
//  shape, press Export and choose where it goes. The same `TranscriptInterface` the API
//  route calls, with the same options, so the two cannot drift.
//
//  The conversation is chosen with `ConversationPicker` in single mode, the same picker and
//  the same rows the scheduled-message composer shows. The run itself lives on
//  `AppModel.transcriptExport`, which is what lets a person leave this page while a long
//  export copies its attachments and come back to find it still going. Everything this page
//  decides (the window, the file type) is in `TranscriptExportOptions.swift`, where a test
//  can reach it.

import AppKit
import BBCore
import BBInterfaces
import BBTranscript
import BlueBubblesServerCore
import SwiftUI

struct TranscriptExportView: View {

  @Bindable var model: AppModel
  /// The chosen conversation, as the picker holds it: zero or one GUID.
  @State private var chosen: Set<String> = []
  @State private var form = TranscriptExportForm()
  /// Why the last press of Export did not reach the save panel, when it did not.
  @State private var preparationError: String?

  private var chosenGUID: String? { chosen.first }

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
      ConversationPicker(model: model, selection: $chosen, mode: .single, visibleRows: 8)
    }
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
    if let preparationError {
      ScreenErrorLine(message: preparationError)
    }
    HStack(spacing: 10) {
      Button("Export…") { Task { await chooseDestinationAndRun() } }
        .buttonStyle(.borderedProminent)
        .disabled(chosenGUID == nil || form.problem != nil)
      if chosenGUID == nil {
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

  /// Names the file from the conversation, asks where it goes, and hands the run off.
  ///
  /// The conversation is read back from the directory by GUID rather than taken from the
  /// picker's row: the picker holds only what was chosen, and the directory is the one place
  /// that knows what the chat is called, which is what the file is named after.
  private func chooseDestinationAndRun() async {
    guard let guid = chosenGUID else { return }
    preparationError = nil
    guard let interfaces = await model.messaging.interfaces() else { return }
    let request = form.request(chatGUID: guid)
    let conversation: ConversationDirectory.Conversation
    do {
      conversation = try await interfaces.conversations.conversation(guid: guid)
    } catch {
      preparationError = DiagnosticText.sentence(for: error)
      return
    }
    let panel = NSSavePanel()
    panel.title = "Export Conversation"
    panel.message = "Choose where to save the transcript."
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.allowedContentTypes = [form.contentType]
    panel.nameFieldStringValue = TranscriptInterface.filename(
      for: TranscriptInterface.chat(from: conversation), request: request)
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    export.start(request, to: destination, using: interfaces)
  }
}
