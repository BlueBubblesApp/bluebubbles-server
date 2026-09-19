//  StatCard
//  A number with a name over it, for the tiles on Home.

import SwiftUI

struct StatCard: View {
  let title: String
  let value: String

  var body: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(value).font(.title2.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.6)
      }
      // One stop instead of two: otherwise swiping through Home reads "Messages", then
      // "12,481", then "Chats", then "36": four stops whose pairing you have to remember.
      // Label and value rather than combined text, so VoiceOver says "Messages, 12,481"
      // and a rotor lands on the name.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(title)
      .accessibilityValue(value)
    }
  }
}
