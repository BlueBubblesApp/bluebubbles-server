//  StatusTone
//  What a piece of status is about, which decides its colour and its symbol.
//
//  One vocabulary for notices, footnotes, status dots, Home's tiles and every list that
//  colours a row by its state. Separate vocabularies drift: with one per surface, a starting
//  server was a warning in the sidebar and unknown on Home, and "unknown" was a question mark
//  in one place and a dashed circle in another. Here a judgement reads the same wherever it
//  is drawn, and a new place to draw one has nothing to invent. A view that colours by state
//  maps its state to a tone and takes `tint` (and `symbol`, where it draws one), never a
//  `Color` of its own.
//
//  Not a View, and not nested in one, so a rule that answers with a tone can be asserted;
//  touching a SwiftUI `View` type from a test process traps.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBCore
import SwiftUI

enum StatusTone: Equatable, Sendable {
  /// No judgement: how something works, or a state that is neither good nor bad (not known
  /// yet, switched off, on its way up). The default, and the one with no colour: a
  /// description is not a problem, and a page full of coloured symbols teaches people to
  /// ignore the coloured one that matters.
  case informational
  /// Working, confirmed. Sparingly: most things that work say nothing at all.
  case good
  /// Not broken, but waiting on a person or short of something.
  case attention
  /// Broken, and it will stay broken until somebody acts.
  case problem

  var tint: Color {
    switch self {
    case .informational: .secondary
    case .good: .green
    case .attention: .orange
    case .problem: .red
    }
  }

  /// The symbol for a tone drawn on its own (a status dot, a tile), where nothing else on
  /// the line says what kind of state it is. A notice or a footnote picks a symbol for what
  /// it SAYS and takes only the colour from here.
  var symbol: String {
    switch self {
    case .informational: "circle.dashed"
    case .good: "checkmark.circle.fill"
    case .attention: "exclamationmark.triangle.fill"
    case .problem: "xmark.circle.fill"
    }
  }
}

extension ServerPhase {

  /// How the server's state reads at a glance, for the sidebar and for Home.
  ///
  /// On its way up or down is `informational`, not `attention`: nothing is wrong and nothing
  /// is asked of anybody, and the sidebar turning amber for the length of every start
  /// trained people to read amber as routine. Waiting on a migration IS asked of somebody.
  var tone: StatusTone {
    switch self {
    case .running: .good
    case .failed: .problem
    case .migrationRequired: .attention
    case .idle, .starting, .waiting, .stopping: .informational
    }
  }
}

extension StatusTone {

  /// An alert's severity as a tone. `info` says nothing about the state of anything, and
  /// `success` is the one alert that reports a thing working.
  init(_ severity: Severity) {
    switch severity {
    case .critical, .error: self = .problem
    case .warning: self = .attention
    case .success: self = .good
    case .info: self = .informational
    }
  }
}
