//  ChoiceCard
//  A large, tappable option with an icon — the shape a first question should take.
//
//  A picker or a list of checkboxes asks someone to read; a grid of cards with a symbol and a
//  sentence each lets them recognise. Used for the goals question and the connection method,
//  in multi- and single-select forms, from one component so the two look like the same kind
//  of decision.

import SwiftUI

struct ChoiceCard: View {
  let title: String
  let summary: String
  let symbol: String
  let isSelected: Bool
  let isMultiSelect: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top) {
          Image(systemName: symbol)
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 34, height: 34)
          Spacer()
          Image(systemName: indicatorSymbol)
            .font(.title3)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            .accessibilityHidden(true)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
          Text(summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
      }
      .padding(18)
      .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
      .glassSurface(cornerRadius: 14, tint: isSelected ? Color.accentColor.opacity(0.12) : nil)
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(
            isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
            lineWidth: isSelected ? 2 : 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .accessibilityLabel("\(title). \(summary)")
  }

  private var indicatorSymbol: String {
    switch (isMultiSelect, isSelected) {
    case (true, true): "checkmark.square.fill"
    case (true, false): "square"
    case (false, true): "checkmark.circle.fill"
    case (false, false): "circle"
    }
  }
}

/// Cards in an adaptive grid: two across on the setup sheet, more on a wide window.
struct ChoiceGrid<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14, alignment: .top)],
      alignment: .leading,
      spacing: 14
    ) {
      content
    }
  }
}
