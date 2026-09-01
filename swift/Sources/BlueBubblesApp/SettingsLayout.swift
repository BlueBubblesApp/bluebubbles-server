//  SettingsLayout
//  The shape every settings surface shares.
//
//  Both settings screens were `Form(.grouped)`, which is dense by design — it is built for
//  fitting many rows into a small inspector. This app is a full window whose settings are read
//  once during setup and then rarely, and where a row often needs a sentence of explanation
//  next to it. Density was working against both: the help text ran as a grey line squeezed
//  under a control, and the glass never showed because a grouped form paints its own
//  background over it.
//
//  So: sections as glass cards, generous rhythm, and one component set used by BOTH the core
//  settings screen and a plugin's manifest-rendered form. That last part is the constraint
//  that matters — if plugin configuration looked visibly cheaper than first-party
//  configuration, the model would be lying about them being the same kind of thing.
//
//  Measurements are stated once here rather than repeated at call sites, so "less compact"
//  stays a property of the app rather than of whichever view was edited most recently.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import SwiftUI

enum SettingsMetrics {
  /// Content stops widening here. A settings row stretched across a 2000pt window puts its
  /// label and its control so far apart they stop reading as one thing.
  static let maximumContentWidth: CGFloat = 760
  static let pagePadding: CGFloat = 28
  static let sectionSpacing: CGFloat = 26
  static let cardPadding: CGFloat = 22
  static let rowSpacing: CGFloat = 20
  /// Controls line up at a common width so a column of them does not look ragged.
  static let controlWidth: CGFloat = 320
}

/// A settings screen: centred, padded, and scrollable.
struct SettingsPage<Content: View>: View {
  /// Extra room at the bottom, for a page with a floating bar over it.
  ///
  /// The bar floats rather than reserving space, which is what makes content run under it
  /// and the glass have something to refract. The cost is that the last row would sit
  /// permanently underneath it, so the page pads itself out of the way.
  var bottomInset: CGFloat = 0
  private let content: Content

  init(bottomInset: CGFloat = 0, @ViewBuilder content: () -> Content) {
    self.bottomInset = bottomInset
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
        content
      }
      .frame(maxWidth: SettingsMetrics.maximumContentWidth, alignment: .leading)
      .padding(SettingsMetrics.pagePadding)
      .padding(.bottom, bottomInset)
      // Centred rather than left-aligned: a column pinned to the left of a wide window
      // leaves a large empty area that reads as a rendering fault.
      .frame(maxWidth: .infinity)
    }
  }
}

/// A titled group of rows on a glass card.
struct SettingsSection<Content: View>: View {
  let title: String
  var subtitle: String?
  var trailing: AnyView?
  private let content: Content

  init(
    _ title: String,
    subtitle: String? = nil,
    trailing: AnyView? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // The header sits OUTSIDE the card, as macOS Settings does — it groups the card
      // rather than being the card's first row, which is what lets the card itself be
      // uniform glass with nothing competing at the top.
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.title3.weight(.semibold))
          if let subtitle {
            Text(subtitle)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer()
        if let trailing { trailing }
      }
      .padding(.horizontal, 4)

      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(SettingsMetrics.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassSurface(cornerRadius: 16)
    }
  }
}

/// One row: a label and explanation on the left, its control on the right.
///
/// The two-column shape is what makes the help text readable. Stacked under a control it
/// competes with the next row's label; beside it, at a fixed control width, the explanation
/// has somewhere to live and the controls line up.
struct SettingsRow<Control: View>: View {
  let title: String
  var help: String?
  /// Extra lines under the row — a validation error, an advisory, a lock notice.
  var footnotes: [SettingsFootnote] = []
  private let control: Control

  init(
    title: String,
    help: String? = nil,
    footnotes: [SettingsFootnote] = [],
    @ViewBuilder control: () -> Control
  ) {
    self.title = title
    self.help = help
    self.footnotes = footnotes
    self.control = control()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 20) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.body)
          if let help {
            Text(help)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 12)
        control
          .frame(maxWidth: SettingsMetrics.controlWidth, alignment: .trailing)
      }

      ForEach(Array(footnotes.enumerated()), id: \.offset) { _, note in
        note
      }
    }
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
  }
}

/// A row whose control needs the full width — a text editor, a list of checkboxes.
struct SettingsWideRow<Control: View>: View {
  let title: String
  var help: String?
  private let control: Control

  init(title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
    self.title = title
    self.help = help
    self.control = control()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.body)
        if let help {
          Text(help).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      control
    }
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
  }
}

/// A line of secondary information attached to a row.
struct SettingsFootnote: View {
  enum Tone { case neutral, warning, error }

  let text: String
  var symbol: String?
  var tone: Tone = .neutral

  private var color: Color {
    switch tone {
    case .neutral: .secondary
    case .warning: .orange
    case .error: .red
    }
  }

  var body: some View {
    Label {
      Text(text).fixedSize(horizontal: false, vertical: true)
    } icon: {
      if let symbol { Image(systemName: symbol) }
    }
    .font(.callout)
    .foregroundStyle(color)
  }
}

/// A hairline between rows, inset from the card's padding.
struct SettingsDivider: View {
  var body: some View {
    Divider().padding(.vertical, 2)
  }
}

/// The most human sentence an error can offer.
///
/// Tried in order of how much thought went into the wording. The last resort renders the
/// value's structure — `tooPredictable(bits: 34.2, minimum: 60.0)` — which is a debugging
/// aid presented as user-facing copy, and was reaching the settings screen.
public func userFacingMessage(_ error: any Error) -> String {
  if let bbError = error as? any BBError { return bbError.body }
  if let localized = (error as? any LocalizedError)?.errorDescription { return localized }
  let described = error.localizedDescription
  // Foundation synthesises "The operation couldn't be completed. (Domain error N.)" for
  // anything that does not implement `LocalizedError`, which says even less than the
  // structure does.
  if !described.isEmpty, !described.contains("couldn\u{2019}t be completed") { return described }
  return String(describing: error)
}
