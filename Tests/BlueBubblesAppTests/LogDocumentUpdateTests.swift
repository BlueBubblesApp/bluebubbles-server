//  LogDocumentUpdateTests
//  What the log viewer edits rather than rebuilds.
//
//  The rule the viewer's cost rests on is the second one: a tail at its cap both appends and
//  drops from the front on every arrival, and an update rule that only knew about appending
//  would rebuild the whole document for exactly the servers that log the most.
//
//  The invariant every case here is really asserting is the same one: whatever the answer,
//  applying it to the lines on screen produces the lines asked for. `applied(_:to:)` states
//  it, so a case cannot pass by agreeing with a wrong expectation.

import BBDiagnostics
import Logging
import Testing

@testable import BlueBubblesApp

@Suite("Log document updates")
struct LogDocumentUpdateTests {

  private func lines(_ texts: String...) -> [LogLine] {
    texts.map { LogLine($0, level: .info) }
  }

  /// The document the viewer would be left holding after carrying out the answer.
  private func applied(_ update: LogDocumentUpdate, to shown: [LogLine], wanted: [LogLine])
    -> [LogLine]
  {
    switch update {
    case .unchanged: shown
    case .replace: wanted
    case .edit(let dropFirst, let appendFrom):
      Array(shown.dropFirst(dropFirst)) + Array(wanted[appendFrom...])
    }
  }

  // MARK: - The shapes

  @Test("The same lines are no work at all")
  func unchanged() {
    let shown = lines("one", "two")
    #expect(LogDocumentUpdate.between(shown, and: shown) == .unchanged)
  }

  @Test("A quiet server appends and drops nothing")
  func appendsOnly() {
    let shown = lines("one", "two")
    let wanted = lines("one", "two", "three")
    #expect(LogDocumentUpdate.between(shown, and: wanted) == .edit(dropFirst: 0, appendFrom: 2))
  }

  /// The case the rule exists for. At the cap every arrival takes a line off the top, and
  /// answering `.replace` here would re-lay out the whole tail several times a second.
  @Test("A tail at its cap drops from the front and still edits")
  func dropsFromTheFront() {
    let shown = lines("one", "two", "three")
    let wanted = lines("two", "three", "four")
    let update = LogDocumentUpdate.between(shown, and: wanted)
    #expect(update == .edit(dropFirst: 1, appendFrom: 2))
    #expect(applied(update, to: shown, wanted: wanted) == wanted)
  }

  @Test("A tail that only scrolled off the top appends nothing")
  func dropsWithoutAppending() {
    let shown = lines("one", "two", "three")
    let wanted = lines("two", "three")
    let update = LogDocumentUpdate.between(shown, and: wanted)
    #expect(update == .edit(dropFirst: 1, appendFrom: 2))
    #expect(applied(update, to: shown, wanted: wanted) == wanted)
  }

  /// Typing in the filter field is this: the lines left have nothing to do with the lines
  /// that were there, and picking them apart costs more than starting again.
  @Test("A changed filter rebuilds")
  func unrelatedLinesRebuild() {
    let shown = lines("connected", "sent", "received")
    let wanted = lines("sent")
    #expect(LogDocumentUpdate.between(shown, and: wanted) == .replace)
  }

  @Test("Clearing the log rebuilds an empty document")
  func clearedRebuilds() {
    #expect(LogDocumentUpdate.between(lines("one"), and: []) == .replace)
  }

  @Test("The first pass rebuilds, and an empty page that stays empty does nothing")
  func firstPass() {
    #expect(LogDocumentUpdate.between([], and: lines("one")) == .replace)
    #expect(LogDocumentUpdate.between([], and: []) == .unchanged)
  }

  // MARK: - The rules that are decisions

  /// Log lines repeat, so an alignment can be found in the wrong place. It does not matter:
  /// the answer is only ever given for an overlap that COMPARED equal, so applying it lands
  /// on the lines asked for whichever alignment was found first.
  @Test("Repeated lines still produce the document that was asked for")
  func repeatedLines() {
    let shown = lines("tick", "tick", "tick")
    let wanted = lines("tick", "tick", "tock")
    let update = LogDocumentUpdate.between(shown, and: wanted)
    #expect(applied(update, to: shown, wanted: wanted) == wanted)
    #expect(update != .replace)
  }

  /// A burst larger than the drift bound is a rebuild on purpose: the search is one array
  /// comparison per candidate, and past this many candidates it costs more than the rebuild.
  @Test("A drop larger than the drift bound rebuilds instead of searching")
  func driftBound() {
    let bound = LogDocumentUpdate.maximumDrift
    let shown = (0..<(bound + 40)).map { LogLine("line \($0)", level: .info) }

    let withinBound = Array(shown.dropFirst(bound))
    let expected = LogDocumentUpdate.edit(dropFirst: bound, appendFrom: 40)
    #expect(LogDocumentUpdate.between(shown, and: withinBound) == expected)

    let pastBound = Array(shown.dropFirst(bound + 1))
    #expect(LogDocumentUpdate.between(shown, and: pastBound) == .replace)
  }

  /// A line's LEVEL is part of what is drawn -- it picks the colour -- so a line whose level
  /// changed is a different line. Nothing in the tail rewrites a level today; this is here so
  /// that a viewer comparing only the text would be caught rather than drawing a red line
  /// black.
  @Test("A line is its text and its level, not its text alone")
  func levelIsPartOfTheLine() {
    let shown = [LogLine("failed", level: .info)]
    let wanted = [LogLine("failed", level: .error)]
    #expect(LogDocumentUpdate.between(shown, and: wanted) == .replace)
  }

  // MARK: - The invariant, over every pair worth trying

  /// The one assertion that covers the shapes nobody thought to write a case for.
  @Test("Applying the answer always lands on the lines asked for")
  func alwaysLandsOnWanted() {
    let pool = lines("alpha", "beta", "gamma", "alpha", "delta")
    for shownCount in 0...pool.count {
      for shownStart in 0...(pool.count - shownCount) {
        let shown = Array(pool[shownStart..<(shownStart + shownCount)])
        for wantedCount in 0...pool.count {
          for wantedStart in 0...(pool.count - wantedCount) {
            let wanted = Array(pool[wantedStart..<(wantedStart + wantedCount)])
            let update = LogDocumentUpdate.between(shown, and: wanted)
            #expect(
              applied(update, to: shown, wanted: wanted) == wanted,
              "\(update) took \(shown.map(\.text)) to the wrong place for \(wanted.map(\.text))"
            )
          }
        }
      }
    }
  }
}
