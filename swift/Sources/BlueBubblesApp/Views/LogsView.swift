//  LogsView
//  The log viewer, with level and source filtering.
//
//  Reads the tail the model follows from the file sink (see `LogObservation.swift`) so the
//  page shows what is already there when it opens and each new line as it is written.
//
//  ## Following
//
//  Following the tail is the default, and it gets out of the way the moment the person
//  scrolls: the way Console.app and every terminal behave. It used to stay on, so scrolling
//  up to read an earlier line was undone by the next line that arrived, and each arrival
//  animated the scroll, so a burst kept the view in motion. Now a scroll away from the bottom
//  turns Follow off and a "Jump to latest" button appears in its place; scrolling back to the
//  bottom, or pressing the button, turns it on again. The auto-scroll itself is unanimated;
//  it happens once per line, and an animation once per line is the motion people complained
//  about.
//
//  Scroll-away detection needs the scroll geometry, which SwiftUI exposes from macOS 15. On
//  macOS 14 the Follow toggle is the only way to pause; it is gated with `#available` so one
//  binary runs correctly on both.
//
//  See `.claude/docs/architecture.md`.

import BBDiagnostics
import Logging
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

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 1) {
            // By position, deliberately: log lines repeat, and a tail only ever appends.
            ForEach(Array(visible.enumerated()), id: \.offset) { index, line in
              Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(colour(for: line.level))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(index)
            }
          }
          .padding(8)
        }
        .followsTail(isFollowing: $isFollowing)
        .onChange(of: visible.count) {
          guard isFollowing, let last = visible.indices.last else { return }
          // Unanimated. This runs once per appended line, and animating it is what made a
          // burst of log lines a page in constant motion.
          proxy.scrollTo(last, anchor: .bottom)
        }
        // Room at the bottom for the bar, so the newest line (the one a follower is
        // watching for) never arrives underneath it.
        .safeAreaPadding(.bottom, FloatingBar<LogLevelFilter>.reservedHeight)
        // The way back, where the person's eye is when they notice they have stopped
        // following. Above the floating bar so the two never overlap.
        .overlay(alignment: .bottomTrailing) {
          if !isFollowing, let last = visible.indices.last {
            Button {
              isFollowing = true
              proxy.scrollTo(last, anchor: .bottom)
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

  private func colour(for level: Logger.Level?) -> Color {
    switch level {
    case .error, .critical: .red
    case .warning: .orange
    default: .primary
    }
  }
}

// MARK: - Scroll-away detection

extension View {
  /// Turns following off when the person scrolls away from the bottom, and on again when
  /// they scroll back to it.
  ///
  /// Only a change in OFFSET counts as the person scrolling. When a line is appended the
  /// content grows and the distance to the bottom grows with it before the auto-scroll
  /// runs; treating that as a scroll-away would turn Follow off on every burst, which is
  /// the opposite of what the feature is for. So a change that also changed the content
  /// height is ignored, and the auto-scroll that follows it, which changes only the
  /// offset, lands at the bottom and leaves Follow on.
  fileprivate func followsTail(isFollowing: Binding<Bool>) -> some View {
    modifier(TailFollowing(isFollowing: isFollowing))
  }
}

private struct TailFollowing: ViewModifier {

  @Binding var isFollowing: Bool

  /// Within this many points of the bottom counts as at the bottom. One line's height
  /// with room to spare, so a person who has scrolled to the end and sees the last line
  /// is following even if the scroll view is not pixel-exact.
  private static let bottomTolerance: CGFloat = 40

  private struct Tail: Equatable {
    let distanceFromBottom: CGFloat
    let contentHeight: CGFloat
  }

  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.onScrollGeometryChange(for: Tail.self) { geometry in
        Tail(
          distanceFromBottom: geometry.contentSize.height - geometry.visibleRect.maxY,
          contentHeight: geometry.contentSize.height
        )
      } action: { previous, current in
        // Content grew or shrank: the tail moved, not the person. See the extension.
        guard current.contentHeight == previous.contentHeight else { return }
        isFollowing = current.distanceFromBottom <= Self.bottomTolerance
      }
    } else {
      // No scroll geometry before macOS 15. The Follow toggle is the way to pause there.
      content
    }
  }
}
