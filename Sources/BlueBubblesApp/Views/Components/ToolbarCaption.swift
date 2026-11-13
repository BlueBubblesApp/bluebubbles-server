//  ToolbarCaption
//  A short secondary figure in a toolbar, beside the buttons it explains: a count, an age.
//
//  Three pages drew it (Home's "Updated … ago", the Audit Log's and Contacts' counts) and only
//  Home had the leading inset. On macOS 26 the toolbar groups a bare `Text` and the button
//  after it into one glass capsule, and a `Text` has no inset of its own, so without the
//  padding it sits flush against the capsule's left edge. Digits are monospaced so a count
//  that changes does not shuffle the buttons beside it.

import SwiftUI

struct ToolbarCaption: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .monospacedDigit()
      .padding(.leading, 8)
  }
}
