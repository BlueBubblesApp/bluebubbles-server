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
  /// A TABLE stops widening later than a settings column does.
  ///
  /// `maximumContentWidth` exists because a settings row's label and its control drift so far
  /// apart on a wide window that they stop reading as one thing. A table has the opposite
  /// problem: its columns are meant to fill, and four of them squeezed into 760 points wrap
  /// the addresses they exist to show. Wide enough for Name, Phone, Email and Account; narrow
  /// enough to stay a centred column on a 2000-point window rather than a full-bleed sheet.
  static let maximumTableWidth: CGFloat = 1100
  static let sectionSpacing: CGFloat = 26
  static let cardPadding: CGFloat = 22
  static let rowSpacing: CGFloat = 20
  /// Controls line up at a common width so a column of them does not look ragged.
  static let controlWidth: CGFloat = 320
}

/// What every page looks like, whether or not it scrolls: a centred column, capped and
/// padded.
///
/// Extracted because there are two page SHAPES and there must not be two spellings of the
/// layout. Nearly every page scrolls a stack of cards (`SettingsPage`); a page built around a
/// `Table` cannot, because a table in a scroll view has no height of its own and gives up the
/// row recycling that makes a long list cheap (`TablePage`). Both are the same column.
///
/// It paints NO background: which one is right differs between the two, and getting that
/// wrong is not cosmetic — see `TablePage`.
private struct PageFrame<Content: View>: View {
  var maximumWidth: CGFloat
  var bottomInset: CGFloat = 0
  /// Whether the column takes all the height it is offered, for a page whose content scrolls
  /// itself rather than scrolling with the page.
  var fillsHeight: Bool = false
  private let content: Content

  init(
    maximumWidth: CGFloat,
    bottomInset: CGFloat = 0,
    fillsHeight: Bool = false,
    @ViewBuilder content: () -> Content
  ) {
    self.maximumWidth = maximumWidth
    self.bottomInset = bottomInset
    self.fillsHeight = fillsHeight
    self.content = content()
  }

  var body: some View {
    content
      .frame(
        maxWidth: maximumWidth, maxHeight: fillsHeight ? .infinity : nil, alignment: .leading
      )
      .padding(SettingsMetrics.pagePadding)
      .padding(.bottom, bottomInset)
      // Centred rather than left-aligned: a column pinned to the left of a wide window
      // leaves a large empty area that reads as a rendering fault.
      .frame(maxWidth: .infinity)
  }
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
    // The scroll view is what paints the window background behind the content, which is why
    // this shape needs no background of its own and `TablePage` does.
    ScrollView {
      PageFrame(maximumWidth: SettingsMetrics.maximumContentWidth, bottomInset: bottomInset) {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
          content
        }
      }
    }
  }
}

/// A page whose content scrolls ITSELF: a `Table`, filling the height it is given.
///
/// The same centred column as `SettingsPage`, without the scroll view, and with the one thing
/// the scroll view was silently providing: **a background**.
///
/// That omission is worth stating, because the symptom pointed somewhere else entirely. With
/// nothing painted behind it, the detail column is a transparent hole: the glass card sampled
/// the desktop through it, and so did the SIDEBAR, whose material samples the same backdrop —
/// so the page tinted the sidebar, and only while the window sat at the top of the screen,
/// where the thing behind it happened to be blue. Nothing in the app was that colour.
struct TablePage<Content: View>: View {
  /// Wider than a settings column, because the reason for that cap does not apply here; see
  /// `SettingsMetrics.maximumTableWidth`.
  var maximumWidth: CGFloat = SettingsMetrics.maximumTableWidth
  private let content: Content

  init(
    maximumWidth: CGFloat = SettingsMetrics.maximumTableWidth, @ViewBuilder content: () -> Content
  ) {
    self.maximumWidth = maximumWidth
    self.content = content()
  }

  var body: some View {
    PageFrame(maximumWidth: maximumWidth, fillsHeight: true) { content }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // What the scroll views elsewhere paint, so the page reads the same as its neighbours.
      .background(Color(nsColor: .windowBackgroundColor))
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
    /// Where a secret that has not been read lives, and how to read it.
    ///
    /// Its own kind rather than `.advice` or `.error`, because it can appear ALONGSIDE
    /// either: the password row can hold a rejected write and still need to say that the
    /// value behind the bullets is in the Keychain. Sharing a kind would make one of the
    /// two vanish, which is the collision this enum exists to prevent.
    case secret
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
