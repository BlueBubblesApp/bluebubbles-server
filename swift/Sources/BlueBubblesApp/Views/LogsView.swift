//  LogsView
//  The log viewer, with level and source filtering.
//
//  See `.claude/docs/architecture.md`.

import SwiftUI

struct LogsView: View {

  @Bindable var model: AppModel

  @State private var lines: [String] = []
  @State private var filter = ""
  @State private var level: LogLevelFilter = .all
  @State private var isFollowing = true

  enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case info = "Info"
    case warning = "Warning"
    case error = "Error"
    var id: String { rawValue }

    var symbol: String {
      switch self {
      case .all: "line.3.horizontal"
      case .info: "info.circle"
      case .warning: "exclamationmark.triangle"
      case .error: "xmark.octagon"
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Filter", text: $filter)
          .textFieldStyle(.roundedBorder)

        Toggle("Follow", isOn: $isFollowing)
          .toggleStyle(.switch)
          .controlSize(.small)

        Button("Copy") {
          // Copies what is ON SCREEN, not the whole file. Someone filtering to one
          // error wants that error in their issue report, not ten thousand lines.
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(visible.joined(separator: "\n"), forType: .string)
        }
        .disabled(visible.isEmpty)
      }
      .padding(10)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(Array(visible.enumerated()), id: \.offset) { index, line in
              Text(line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(colour(for: line))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(index)
            }
          }
          .padding(8)
        }
        .onChange(of: visible.count) {
          guard isFollowing, let last = visible.indices.last else { return }
          withAnimation { proxy.scrollTo(last, anchor: .bottom) }
        }
        // Room at the bottom for the bar, so the newest line — the one a follower is
        // watching for — never arrives underneath it.
        .safeAreaPadding(.bottom, FloatingBar<LogLevelFilter>.reservedHeight)
      }
    }
    // The same control as the settings tabs, for the same reason: it is a choice between
    // a few views of the page, and it belongs over the content it filters rather than in
    // a header competing with the search field.
    .overlay(alignment: .bottom) {
      FloatingBar(
        selection: $level,
        items: LogLevelFilter.allCases.map {
          FloatingBarItem(value: $0, title: $0.rawValue, symbol: $0.symbol)
        }
      )
    }
    .task { await follow() }
  }

  private var visible: [String] {
    lines.filter { line in
      let matchesLevel =
        switch level {
        case .all: true
        case .info: line.contains("[info]")
        case .warning: line.contains("[warning]")
        case .error: line.contains("[error]") || line.contains("[critical]")
        }
      let matchesText =
        filter.isEmpty
        || line.localizedCaseInsensitiveContains(filter)
      return matchesLevel && matchesText
    }
  }

  private func colour(for line: String) -> Color {
    if line.contains("[error]") || line.contains("[critical]") { return .red }
    if line.contains("[warning]") { return .orange }
    return .primary
  }

  /// Tails the file the server is writing.
  ///
  /// Polled rather than streamed: the log is written by a `FileSink` shared with every
  /// other subsystem, and adding a fan-out from it purely for one window would put UI
  /// concerns into the logging path. Two seconds is imperceptible for reading logs.
  private func follow() async {
    while !Task.isCancelled {
      if let sink = model.logSink {
        lines = sink.tail(lines: 2000)
      }
      try? await Task.sleep(for: .seconds(2))
    }
  }
}
