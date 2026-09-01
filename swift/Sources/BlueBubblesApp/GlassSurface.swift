//  GlassSurface
//  Liquid Glass on macOS 26, a material below it.
//
//  Applied to chrome only — the sidebar, toolbars, and stat cards. Content surfaces stay
//  opaque: glass behind a paragraph of text reduces contrast against whatever happens to be
//  on the desktop behind the window, and log lines and message text are the things people
//  actually read.
//
//  See `.claude/docs/architecture.md`.

import SwiftUI

extension View {
  /// Glass where available, `.regularMaterial` otherwise.
  ///
  /// Gated with `#available` rather than a compile-time check so ONE binary runs correctly
  /// on every supported OS. A `#if canImport` here would bake the newest SDK's behaviour
  /// into a build that also has to run on macOS 14.
  ///
  /// `tint` washes the surface with a colour rather than replacing it — the material still
  /// samples what is behind the window. Keep it faint: this is for saying "this one is
  /// different from its neighbours", not for colouring a card in.
  @ViewBuilder
  func glassSurface(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
    if #available(macOS 26.0, *) {
      if let tint {
        self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
      } else {
        self.glassEffect(in: .rect(cornerRadius: cornerRadius))
      }
    } else {
      self.background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(.regularMaterial)
          // Over the material, not under it: a tint behind `.regularMaterial` is
          // blurred away to nothing.
          .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
              .fill(tint ?? .clear)
          )
      )
    }
  }
}

/// A card, used for the status tiles on Home.
struct GlassCard<Content: View>: View {
  /// Faint wash over the card's glass, for the rare case where one card in a stack has to
  /// read as different from the others. `nil` — the default, and what nearly every call
  /// site wants — is the plain surface.
  var tint: Color?
  var content: Content

  init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
    self.tint = tint
    self.content = content()
  }

  var body: some View {
    content
      // Matched to `SettingsMetrics.cardPadding` and the settings cards' corner radius,
      // so a card on Home and a card on a settings page are visibly the same object.
      .padding(SettingsMetrics.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassSurface(cornerRadius: 16, tint: tint)
  }
}

/// A labelled status dot.
///
/// The colour is never the only signal — every use pairs it with text. Roughly one in twelve
/// men has some form of colour-vision deficiency, and red-versus-green is the pairing they
/// most often cannot separate, which is exactly the distinction a status indicator makes.
struct StatusDot: View {
  enum Level { case ok, warning, bad, unknown }

  var level: Level
  var label: String

  private var color: Color {
    switch level {
    case .ok: .green
    case .warning: .orange
    case .bad: .red
    case .unknown: .secondary
    }
  }

  private var symbol: String {
    switch level {
    case .ok: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .bad: "xmark.circle.fill"
    case .unknown: "questionmark.circle.fill"
    }
  }

  var body: some View {
    Label {
      Text(label)
    } icon: {
      Image(systemName: symbol).foregroundStyle(color)
    }
    .accessibilityLabel("\(label)")
  }
}
