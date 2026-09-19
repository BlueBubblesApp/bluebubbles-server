//  Tag
//  A short word in a capsule: a platform, a codec, "recommended", "built-in".
//
//  One component, because five pages had drawn their own (at three different paddings, two
//  weights and three opacities) and the difference between them was not a decision anyone
//  had made. A tinted tag is the same object with a colour behind it, for the handful of
//  words that carry a judgement: "Required" in red, "Recommended" in orange.

import SwiftUI

struct Tag: View {

  let text: String
  /// A wash behind the word, for a tag that judges rather than describes. Nil (the default,
  /// and what nearly every call site wants) is the neutral capsule.
  var tint: Color?

  init(_ text: String, tint: Color? = nil) {
    self.text = text
    self.tint = tint
  }

  var body: some View {
    Text(text)
      // A judgement reads a step heavier than a description, so the two are tellable apart
      // beside each other without the colour being the only difference.
      .font(.caption2.weight(tint == nil ? .regular : .semibold))
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background((tint ?? Color.secondary).opacity(0.15), in: Capsule())
  }
}
