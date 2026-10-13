//  StatCard
//  A number with a name over it, for the tiles on Home.

import SwiftUI

struct StatCard: View {
  let title: String
  let value: String
  /// A second, quieter line: which method is connected, what the count is of.
  var detail: String?
  /// Set for a tile that is a judgement (a service failing, a helper disconnected) and left
  /// nil for one that is only a count. The colour is never the only signal: the value says
  /// the same thing in words.
  var tone: StatusTone?
  /// What pressing the tile does: usually, showing the card that explains it. Nil for a tile
  /// that is only a figure.
  var action: (() -> Void)?

  var body: some View {
    if let action {
      // The whole tile is the control. Named for what it is rather than what it does, because
      // VoiceOver reads the value it shows and the hint says what pressing it does.
      Button(action: action) { card }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(detail.map { "\(value), \($0)" } ?? value)
        .accessibilityHint("Shows the details below")
    } else {
      card
    }
  }

  private var card: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          if let tone {
            Image(systemName: tone.symbol)
              .foregroundStyle(tone.tint)
              .accessibilityHidden(true)
          }
          // Readable inside a `Skeleton`, so the grey tile still says what it counts.
          Text(title).font(.caption).foregroundStyle(.secondary).unredacted()
        }
        Text(value).font(.title2.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        if let detail {
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      // Grows to the height its grid gives it, so a tile with no detail line is as tall as
      // one with; see `EqualHeightGrid`.
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      // One stop instead of two: otherwise swiping through Home reads "Messages", then
      // "12,481", then "Chats", then "36": four stops whose pairing you have to remember.
      // Label and value rather than combined text, so VoiceOver says "Messages, 12,481"
      // and a rotor lands on the name.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(title)
      .accessibilityValue(detail.map { "\(value), \($0)" } ?? value)
    }
  }
}
