//  Skeleton
//  A card's own layout, greyed out, while its first read is in flight.
//
//  The alternative was a spinner, and a spinner is the wrong height: `LoadingNotice` is a
//  line and a wheel, and what replaced it on Home was two grids of cards with charts, so the
//  page reflowed the moment a read landed and every card in the grid jumped to the new
//  tallest. This draws the REAL layout from a placeholder value under redaction while
//  loading, and from the real value once it lands, so the content arrives where the skeleton
//  was, at the same height.
//
//  ONE view, swapped in place, and no crossfade. The first version drew a redacted copy as an
//  overlay over the real card and faded between them, and on macOS 26 that put two glass
//  surfaces on top of each other inside the page's `GlassEffectContainer`, whose whole job is
//  to MERGE glass shapes that touch: the cards blended into one smeared shape for the length
//  of the fade and sometimes stayed that way. A card that is only ever one surface cannot
//  merge with itself.
//
//  And no animation at all. The skeleton is dimmed, not pulsed. A pulse is a repeating
//  opacity change on a glass card, and a pixel changing inside glass re-samples the glass:
//  the whole page's container was re-composited at frame rate for as long as any read was
//  in flight, which on a Mac with years of messages is long enough to be what the Energy tab
//  shows. The dim reads as waiting on its own, the swap to content is instant, and Reduce
//  Motion has nothing left to ask for.
//
//  Redacted content keeps its accessibility labels, so a skeleton would read its placeholder
//  numbers to VoiceOver as if they were real. While loading the card is one element that says
//  "Loading …", takes no clicks, and holds no focus.

import SwiftUI

struct Skeleton<Value, Content: View>: View {
  let value: Value
  /// What the layout is drawn from while loading. Typed sample data on the value's own type,
  /// sized like a real result so the skeleton is the loaded height, including the rows that
  /// only exist once a value is present. Built once and reused, never on every body: see
  /// `HomeModel.Glance.sample`.
  let placeholder: Value
  let isLoading: Bool
  /// Completes "Loading …" for VoiceOver: "message activity", "delivery". Never capitalised
  /// and never a sentence.
  let subject: String
  private let content: (Value) -> Content

  init(
    value: Value, placeholder: Value, isLoading: Bool, subject: String,
    @ViewBuilder content: @escaping (Value) -> Content
  ) {
    self.value = value
    self.placeholder = placeholder
    self.isLoading = isLoading
    self.subject = subject
    self.content = content
  }

  var body: some View {
    content(isLoading ? placeholder : value)
      .redacted(reason: isLoading ? .placeholder : [])
      .opacity(isLoading ? 0.55 : 1)
      .disabled(isLoading)
      .allowsHitTesting(!isLoading)
      .accessibilityElement(children: isLoading ? .ignore : .contain)
      .accessibilityLabel(isLoading ? "Loading \(subject)" : "")
  }
}

// MARK: - Charts

extension View {
  /// A chart's frame, and a flat block of that height while the content is a placeholder.
  ///
  /// Redaction greys text and images and leaves a chart drawing its marks, so a chart fed
  /// with placeholder data reads as data. A block reads as "not yet". Every chart on Home
  /// takes this in place of `.frame(height:)`, so a chart inside a `Skeleton` and the same
  /// chart outside one are the same height.
  func chartFrame(height: CGFloat) -> some View {
    modifier(ChartFrame(height: height))
  }
}

private struct ChartFrame: ViewModifier {
  @Environment(\.redactionReasons) private var redactionReasons
  let height: CGFloat

  func body(content: Content) -> some View {
    if redactionReasons.contains(.placeholder) {
      // `.quaternary` rather than a material, so Reduce Transparency changes nothing here.
      RoundedRectangle(cornerRadius: SettingsMetrics.fieldCornerRadius, style: .continuous)
        .fill(.quaternary)
        .frame(height: height)
    } else {
      content.frame(height: height)
    }
  }
}
