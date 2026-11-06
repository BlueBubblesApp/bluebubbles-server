//  TitledCard
//  A glass card that opens with a headline, with an optional accessory at the headline's
//  trailing edge.
//
//  Nine cards drew this by hand (five on Guides, two on API & Webhooks, two on Firebase) and
//  spaced the headline from what followed it at 6, 8 and 10 points, so two cards side by side
//  on one page sat their content at different distances under the title. One component, one
//  spacing: `SettingsMetrics.cardStackSpacing`, the same gap a card's other blocks keep.
//
//  NOT for a card whose title is something else: a `Label` with a symbol (`HomeCard`), a
//  device name inside a row (the Firebase devices list), a notice (`NoticeCard`). Those are
//  different shapes, and folding them in would grow this a parameter per exception.
//  `SharedComponentPolicyTests` refuses a `GlassCard` that opens with a literal headline.

import SwiftUI

struct TitledCard<Content: View, Trailing: View>: View {
  let title: String
  /// What sits at the headline's trailing edge: a tag, a spinner. A `ViewBuilder` rather
  /// than an erased view, the `SettingsSection` shape.
  private let trailing: Trailing
  private let content: Content

  /// Written as two trailing closures (`TitledCard("Title") { body } trailing: { tag }`).
  init(
    _ title: String,
    @ViewBuilder content: () -> Content,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.content = content()
    self.trailing = trailing()
  }

  init(_ title: String, @ViewBuilder content: () -> Content) where Trailing == EmptyView {
    self.init(title, content: content, trailing: { EmptyView() })
  }

  var body: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: SettingsMetrics.cardStackSpacing) {
        HStack {
          Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
          Spacer()
          trailing
        }
        content
      }
    }
  }
}
