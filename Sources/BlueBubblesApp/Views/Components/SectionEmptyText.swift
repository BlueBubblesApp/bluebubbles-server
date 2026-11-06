//  SectionEmptyText
//  The one quiet line a section shows when it has nothing in it: "Nothing is blocked."
//
//  Nine sections drew this by hand, in callout, caption and body, some with room above and
//  below and some without, so an empty section looked different depending on which page it
//  was on. One look: callout, secondary, wrapping, with the vertical room a row would have.
//
//  NOT for a page or a list that is empty as a whole, which is an invitation with an action
//  (`ContentUnavailableView`, the `ListPage` empty slot). This is the line inside a section
//  whose header already says what it is about. `SharedComponentPolicyTests` refuses a
//  `Text("No …")`, `Text("None …")` or `Text("Nothing …")` drawn anywhere else under `Views/`.

import SwiftUI

struct SectionEmptyText: View {
  /// A sentence saying what is absent: "None registered.", not "Empty".
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, 4)
  }
}
