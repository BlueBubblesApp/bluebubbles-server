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

  /// No raw value: the case is the identity and the title is a label, the same rule
  /// `Destination` and `SettingsTab` follow.
  enum LogLevelFilter: CaseIterable, Identifiable, Hashable {
    case all
    case info
    case warning
    case error

    var id: Self { self }

    var title: String {
      switch self {
      case .all: "All"
      case .info: "Info"
      case .warning: "Warning"
      case .error: "Error"
      }
    }

    var symbol: String {
      switch self {
      case .all: "line.3.horizontal"
      case .info: "info.circle"
      case .warning: "exclamationmark.triangle"
      case .error: "xmark.octagon"
      }
    }

    /// Whether a line at this level belongs in this view.
    ///
    /// Compared against the level `LogLine` parsed out of the written format, not found
    /// anywhere in the text. A line with no level (a crash report, a subprocess's stderr)
    /// appears only under All, because its level is unknown rather than `info`.
    func admits(_ level: Logger.Level?) -> Bool {
      switch self {
      case .all: true
      case .info: level == .info
      case .warning: level == .warning
      // Critical is rarer and worse than error, and someone filtering to errors wants it.
      case .error: level == .error || level == .critical
      }
    }
  }

  var body: some View {
    // Once per render, not once per use: the filter runs over the whole tail, and this
    // value was being computed three times per redraw.
    let visible = self.visible
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
  }

  private var visible: [LogLine] {
    model.logLines.filter { line in
      guard level.admits(line.level) else { return false }
      return filter.isEmpty || line.text.localizedCaseInsensitiveContains(filter)
    }
  }

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
