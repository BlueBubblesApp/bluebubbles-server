//  LogsView
//  The log viewer, with level and source filtering.
//
//  Reads the tail the model follows from the file sink (see `LogObservation.swift`) so the
//  page shows what is already there when it opens and each new line as it is written.
//
//  The lines themselves are `LogTextView`, one read-only text document rather than a stack of
//  `Text` rows, because a SwiftUI selection cannot span two `Text`s and copying a stack trace
//  out of the log meant copying it a line at a time. That file has the rest of it, following
//  the tail included.
//
//  See `.claude/docs/architecture.md`.

import BBDiagnostics
import SwiftUI

struct LogsView: View {

  @Bindable var model: AppModel

  @State private var filter = ""
  @State private var level: LogLevelFilter = .all
  @State private var isFollowing = true
  @State private var isConfirmingClear = false

  // `LogLevelFilter` and the two-filter rule are `LogFiltering.swift`, not nested here: a
  // type inside a View cannot be named from a test, so the level rules were unasserted.

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Filter", text: $filter)
          .textFieldStyle(.roundedBorder)

        Toggle("Follow", isOn: $isFollowing)
          .toggleStyle(.switch)
          .controlSize(.small)

        if let url = model.logFileURL {
          // For the support thread that wants the whole file rather than the lines on
          // screen. The path is the sink's own, so this cannot point at a default that is
          // not the one in use.
          Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
          .help("Show the log file in the Finder")

          // The folder rather than the file: the rotated copies live beside it, and a
          // support thread that wants "everything" wants the folder.
          Button("Open Folder") {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
          }
          .help("Open the folder that holds the log and its rotated copies")

          Button("Clear…", role: .destructive) {
            isConfirmingClear = true
          }
          .help("Empty the log file and delete its rotated copies")
          .confirmationDialog(
            "Clear the log?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
          ) {
            Button("Clear Log", role: .destructive) { model.clearLog() }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text(
              "The log file and its rotated copies are emptied. Nothing else is affected, "
                + "and logging carries on into the empty file.")
          }
        }

        Button("Copy") {
          // Copies what is ON SCREEN, not the whole file. Someone filtering to one
          // error wants that error in their issue report, not ten thousand lines.
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(
            visible.map(\.text).joined(separator: "\n"), forType: .string)
        }
        .disabled(visible.isEmpty)
      }
      .padding(10)

      Divider()

      LogTextView(
        lines: visible,
        isFollowing: $isFollowing,
        bottomInset: FloatingBar<LogLevelFilter>.reservedHeight
      )
      // The way back, where the person's eye is when they notice they have stopped
      // following. Above the floating bar so the two never overlap.
      .overlay(alignment: .bottomTrailing) {
        if !isFollowing, !visible.isEmpty {
          Button {
            isFollowing = true
          } label: {
            Label("Jump to latest", systemImage: "arrow.down.to.line")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .padding(.trailing, 16)
          .padding(.bottom, FloatingBar<LogLevelFilter>.reservedHeight)
        }
      }
    }
    // The same control as the settings tabs, for the same reason: it is a choice between
    // a few views of the page, and it belongs over the content it filters rather than in
    // a header competing with the search field.
    .overlay(alignment: .bottom) {
      FloatingBar(
        selection: $level,
        items: LogLevelFilter.allCases.map {
          FloatingBarItem(value: $0, title: $0.title, symbol: $0.symbol)
        }
      )
    }
    // ONE pass per burst, not one per line. Keyed on the two filters and a version that
    // moves whenever the tail does -- the line count cannot serve, because once the tail is
    // at its 2,000-line cap every append also drops one from the front and the count stops
    // moving.
    //
    // The short sleep coalesces: a server logging twenty lines a second produced twenty
    // full passes a second, and now produces about eight. A line can be up to that late
    // arriving on screen, which in a log tail nobody can perceive.
    .task(id: LogFiltering.Key(level: level, query: filter, version: model.logLinesVersion)) {
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      visible = LogFiltering.visible(model.logLines, level: level, query: filter)
    }
  }

  /// HELD, not recomputed per render.
  ///
  /// `logLines` is observable and the tail appends constantly, so every line invalidated the
  /// view, whose body then re-filtered the whole 2,000-line tail -- several times over, since
  /// `visible` is read by the list, the follow-to-bottom handler and the jump button. With a
  /// query typed that was 2.38ms of ICU per line, which on a busy server is a quarter of a
  /// core doing nothing but re-answering the same question.
  @State private var visible: [LogLine] = []
}
