//  ActionOutcomeLine
//  An `ActionOutcome`, drawn under the button that produced it.
//
//  A failure is an `ErrorLine`, so it reads like every other failure in the app; the other
//  two are a quiet line, because a button that did what it says needs confirming, not
//  celebrating.

import SwiftUI

struct ActionOutcomeLine: View {
  let outcome: ActionOutcome

  init(_ outcome: ActionOutcome) {
    self.outcome = outcome
  }

  var body: some View {
    if outcome.isFailure {
      ErrorLine(outcome.text)
    } else {
      Label(outcome.text, systemImage: outcome.symbol)
        .font(.callout)
        .foregroundStyle(outcome.tone.tint)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
