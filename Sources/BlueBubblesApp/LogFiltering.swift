//  LogFiltering
//  Which log lines the viewer shows, for a chosen level and a typed query.
//
//  `LogLevelFilter` was nested inside `LogsView`, which put it out of reach of a test:
//  touching a SwiftUI `View` type from a test process traps, and a nested type cannot be
//  named without naming the view. So the level rules — including the two that are decisions
//  rather than mechanics, that `critical` belongs under Error and that a line with NO level
//  appears only under All — were asserted by nothing.
//
//  Not a View, so they can be. See `Sources/BlueBubblesApp/CLAUDE.md`: a decision that
//  deserves a test cannot live on the view that uses it.

import BBDiagnostics
import Logging

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

/// The viewer's two filters, applied together.
enum LogFiltering {

  /// Lines that pass both the level filter and the typed query.
  ///
  /// Case- and diacritic-insensitive on the text, because the query is something a person
  /// typed while reading, not a pattern. An empty query filters nothing rather than
  /// everything: a blank field is "no query", which is the state the page opens in.
  static func visible(
    _ lines: [LogLine], level: LogLevelFilter, query: String
  ) -> [LogLine] {
    // Folded ONCE, not once per line. `localizedCaseInsensitiveContains` case-folds both
    // sides on every call, which is an ICU call per line over a 2,000-line tail -- and the
    // viewer ran this on every appended line, so a busy server spent it twenty times a
    // second. Folding the query here and comparing folded-to-folded is the same
    // case-insensitive answer.
    let needle = query.trimmingCharacters(in: .whitespaces)
      .folding(options: .caseInsensitive, locale: .current)
    return lines.filter { line in
      guard level.admits(line.level) else { return false }
      guard !needle.isEmpty else { return true }
      return line.text.folding(options: .caseInsensitive, locale: .current).contains(needle)
    }
  }

  /// What a viewer keys its filtering on: the two filters, and a version that moves whenever
  /// the tail does.
  struct Key: Equatable {
    let level: LogLevelFilter
    let query: String
    let version: UInt64
  }
}
