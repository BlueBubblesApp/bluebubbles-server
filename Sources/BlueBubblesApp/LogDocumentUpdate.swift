//  LogDocumentUpdate
//  What has to change in the log viewer's text to show a new set of lines.
//
//  The viewer draws its lines into ONE text document so a selection can span them (see
//  `Views/LogTextView.swift`). One document means the whole tail is re-laid out whenever it
//  is replaced wholesale, and the tail changes several times a second on a busy server, so
//  the viewer asks this what actually changed and edits only that.
//
//  Two shapes cover nearly every update, and the second is the one that matters. A quiet
//  server APPENDS: the lines on screen are still there with more after them. A busy one
//  appends and DROPS FROM THE FRONT, because the tail is capped at `AppModel.logLinesKept`
//  and every arrival past the cap takes one off the top. An update rule that only knew about
//  appending would fall back to a full rebuild on every arrival for exactly the servers that
//  log the most, which is the opposite of what it is for.
//
//  Off the view because it is a decision, not mechanics: see `Sources/BlueBubblesApp/CLAUDE.md`.

import BBDiagnostics

/// How to get the document from the lines it shows to the lines it should show.
enum LogDocumentUpdate: Equatable {

  /// The document already shows exactly these lines.
  case unchanged

  /// Take `dropFirst` lines off the top, then append the lines from `appendFrom` onwards.
  ///
  /// Either half can be zero: a plain append drops nothing, and a tail that has only
  /// scrolled off the top appends nothing.
  case edit(dropFirst: Int, appendFrom: Int)

  /// Nothing worth keeping. Build the document again.
  case replace
}

extension LogDocumentUpdate {

  /// How far the front of the tail may have moved before a rebuild is the cheaper answer.
  ///
  /// The search below is one array comparison per candidate, so an unbounded search over a
  /// 2,000-line tail that has nothing in common with the last one costs more than the
  /// rebuild it is trying to avoid. The viewer coalesces its passes to roughly eight a
  /// second, so this is the number of lines a server would have to log in about an eighth of
  /// a second to outrun it -- and a burst that large is a rebuild nobody perceives.
  static let maximumDrift = 256

  /// What changed between the lines on screen and the lines to show.
  ///
  /// Compares the lines themselves rather than trusting a count. The count cannot answer:
  /// once the tail is at its cap every arrival both appends and drops, so the count stops
  /// moving while the content keeps changing -- the same trap `logLinesVersion` exists for.
  static func between(_ shown: [LogLine], and wanted: [LogLine]) -> LogDocumentUpdate {
    // An empty document is a rebuild, and a rebuild of nothing is what clears one.
    guard !shown.isEmpty else { return wanted.isEmpty ? .unchanged : .replace }

    for dropped in 0..<min(shown.count, maximumDrift + 1) {
      let kept = shown.count - dropped
      // More lines kept than wanted: the tail lost lines off its END, which no amount of
      // dropping from the front explains. A larger drop may still line up.
      guard kept <= wanted.count else { continue }
      guard shown[dropped...].elementsEqual(wanted[..<kept]) else { continue }
      if dropped == 0, kept == wanted.count { return .unchanged }
      return .edit(dropFirst: dropped, appendFrom: kept)
    }
    return .replace
  }
}
