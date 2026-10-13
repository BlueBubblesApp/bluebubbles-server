//  ServiceStatusLine
//  One line on what a service is doing, when that is worth saying.
//
//  Five places drew this `Label` by hand: the Integrations list and its detail page, the
//  Notifications page, the HTTP listener section and a connection method's published
//  address. They agreed on the colour rule and on nothing else: two sizes, wrapping on three
//  of them and truncating on two, and one site re-declared `ServiceStatusSummary.Line` as a
//  tuple of its own so its sentences could not be asserted.
//
//  The WORDS are `ServiceStatusSummary`'s, off the view where a test can read them. This only
//  draws them, in the line's `StatusTone`, so a status line and a notice that both mean "worth
//  noticing" are the same orange.

import SwiftUI

struct ServiceStatusLine: View {

  /// Where the line sits, which decides its size and nothing else.
  enum Placement {
    /// Under a row's summary, in a list of rows: the caption size the summary's own
    /// secondary text steps down to.
    case row
    /// On its own in a section or a page header, beside text at the callout size.
    case section
  }

  let line: ServiceStatusSummary.Line
  var placement: Placement = .section

  init(_ line: ServiceStatusSummary.Line, placement: Placement = .section) {
    self.line = line
    self.placement = placement
  }

  var body: some View {
    Label(line.text, systemImage: line.symbol)
      .font(placement == .row ? .caption : .callout)
      .foregroundStyle(line.tone.tint)
      // Wraps rather than truncating: a failure's reason is the part of the line somebody
      // came to read, and it is the end of it.
      .fixedSize(horizontal: false, vertical: true)
  }
}
