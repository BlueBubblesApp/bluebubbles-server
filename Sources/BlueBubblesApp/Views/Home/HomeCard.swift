//  HomeCard
//  One of Home's summary cards: a heading, a way to the page that owns the detail, and the
//  summary under them.
//
//  Glass, like the tiles above it and like the cards the old Home had. The rule in
//  `GlassSurface.swift` (chrome samples, content does not) is about SIZE: a page-filling table
//  of text samples a page of desktop, and a card of a few figures samples texture. These are
//  the second kind, and a Home that was mostly opaque read as a different app from the rest
//  of the window.

import SwiftUI

struct HomeCard<Content: View>: View {
  let title: String
  let symbol: String
  /// The page that owns this summary, and the words on the button that goes there. Nil for a
  /// card that is the only place its content lives.
  var destination: (label: String, action: () -> Void)?
  private let content: Content

  init(
    _ title: String,
    symbol: String,
    destination: (label: String, action: () -> Void)? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.symbol = symbol
    self.destination = destination
    self.content = content()
  }

  var body: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: SettingsMetrics.cardStackSpacing) {
        HStack(spacing: 8) {
          // Readable inside a `Skeleton`, so the grey card still says which card it is.
          Label(title, systemImage: symbol).font(.headline).unredacted()
          Spacer(minLength: 8)
          if let destination {
            Button(destination.label, action: destination.action)
              .controlSize(.small)
          }
        }
        content
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }
}

/// A label and a number on one line, the unit every Home card is built from.
struct HomeFigure: View {
  let label: String
  let value: String
  var tone: StatusTone?

  var body: some View {
    LabeledContent {
      Text(value)
        .monospacedDigit()
        .foregroundStyle(tone.map(\.tint) ?? .primary)
    } label: {
      Text(label).foregroundStyle(.secondary)
    }
    .font(.callout)
  }
}
