//  SettingsLayout
//  The shape every settings surface shares.
//
//  Both settings screens were `Form(.grouped)`, which is dense by design: it is built for
//  fitting many rows into a small inspector. This app is a full window whose settings are read
//  once during setup and then rarely, and where a row often needs a sentence of explanation
//  next to it. Density was working against both: the help text ran as a grey line squeezed
//  under a control, and the glass never showed because a grouped form paints its own
//  background over it.
//
//  So: sections as glass cards, generous rhythm, and one component set used by BOTH the core
//  settings screen and a plugin's manifest-rendered form. That last part is the constraint
//  that matters: if plugin configuration looked visibly cheaper than first-party
//  configuration, the model would be lying about them being the same kind of thing.
//
//  Measurements are stated once here rather than repeated at call sites, so "less compact"
//  stays a property of the app rather than of whichever view was edited most recently.
//
//  See `.claude/docs/architecture.md`.

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
struct SettingsSection<Content: View, Trailing: View>: View {
  let title: String
  var subtitle: String?
  /// What sits at the header's trailing edge: a count, a tag, a button. A `ViewBuilder`
  /// rather than an erased view, so a caller writes the view and its condition in place
  /// and nothing is boxed.
  private let trailing: Trailing
  private let content: Content

  /// Written as two trailing closures (`SettingsSection("Title") { rows } trailing: { tag }`)
  /// the way `Label` takes its title and icon.
  init(
    _ title: String,
    subtitle: String? = nil,
    @ViewBuilder content: () -> Content,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
    self.trailing = trailing()
  }

  init(
    _ title: String,
    subtitle: String? = nil,
    @ViewBuilder content: () -> Content
  ) where Trailing == EmptyView {
    self.title = title
    self.subtitle = subtitle
    self.trailing = EmptyView()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // The header sits OUTSIDE the card, as macOS Settings does: it groups the card
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
        trailing
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
  /// Extra lines under the row: a validation error, an advisory, a lock notice.
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
          // The row knows the control's name and the control does not: almost every one
          // of these is a `Picker("", …)` or a `TextField` under `.labelsHidden()`, which
          // renders correctly and reads to VoiceOver as an unnamed text field. Naming it
          // here fixes every settings control in the app at once, rather than one
          // `.accessibilityLabel` per call site that the next row would forget.
          .accessibilityLabel(title)
          .accessibilityHint(help ?? "")
      }

      ForEach(footnotes) { note in note }
    }
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
  }
}

/// A row whose control needs the full width: a text editor, a list of checkboxes.
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
        // Same reason as `SettingsRow`. A wide row's control is usually a text editor or a
        // list of checkboxes, which is if anything more confusing to meet unnamed.
        .accessibilityLabel(title)
        .accessibilityHint(help ?? "")
    }
    .padding(.vertical, SettingsMetrics.rowSpacing / 2)
  }
}

/// A line of secondary information attached to a row.
struct SettingsFootnote: View, Identifiable {

  /// What this note is about, and its identity in a list of them.
  ///
  /// A row shows at most one note of each kind, so the kind is what a `ForEach` keys on.
  /// Keyed by TEXT, which is what four of them did, two notes that happened to read the
  /// same collided: SwiftUI reports a duplicate id and renders one of them unpredictably.
  /// It could not happen with today's call sites, and that is exactly the invariant worth
  /// writing down rather than relying on.
  enum Kind: Hashable {
    /// The field holds something not yet written.
    case unsaved
    /// Set on the command line, in the config file, or by another field: not editable.
    case locked
    /// Required and empty.
    case required
    /// Advisory: a weak password, a surprising behaviour. Never a gate.
    case advice
    /// The write was refused, or the read failed.
    case error
    /// Anything else: a status line, an explanation, a count. The default, and the only
    /// kind that appears outside a list of footnotes.
    case status
  }

  enum Tone { case neutral, warning, error }

  let text: String
  var kind: Kind = .status
  var symbol: String?
  var tone: Tone = .neutral

  // `nonisolated` because `View` is a main-actor protocol, so without it the `id` this
  // type inherits from it is main-actor too, and `Identifiable` does not promise that.
  // It reads one stored value and touches nothing else, so the isolation buys nothing.
  nonisolated var id: Kind { kind }

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
