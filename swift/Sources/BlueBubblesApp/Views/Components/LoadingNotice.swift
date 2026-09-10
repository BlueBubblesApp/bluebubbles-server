//  LoadingNotice
//  What a page shows between asking and knowing.
//
//  Every list page here reads from the server, and every one of them decided what to draw by
//  asking whether the collection was empty. It is empty before the first result lands, so
//  each page announced its empty state ("No devices", "Nothing scheduled", "No conversations
//  were found") for as long as the read took, and then replaced it with rows. On a Mac with
//  hundreds of conversations the wrong answer was the one on screen for the whole wait.
//
//  The pages had already learned half of this: each guards its empty state with a check that
//  the read did not FAIL, because "nothing scheduled" over a refused read is a lie with a
//  button on it. A read that has not finished is the same lie a moment earlier, and
//  `ScreenState` already distinguishes it: `idle` and `loading` are separate cases, and the
//  comment on them says this is why. The pages were discarding that by reading only
//  `state.value`.
//
//  So this is the third branch, once, rather than five spellings of it.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import SwiftUI

struct LoadingNotice: View {

  /// What is being read, as a plural noun in the page's own vocabulary: "devices",
  /// "scheduled messages". It completes "Loading …", so it is never capitalised and never a
  /// sentence.
  let subject: String

  var body: some View {
    VStack(spacing: 10) {
      ProgressView().controlSize(.large)
      Text("Loading \(subject)…")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // One stop rather than two, and the spinner alone has nothing to say.
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Loading \(subject)")
  }
}
