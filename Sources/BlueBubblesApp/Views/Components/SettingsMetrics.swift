//  SettingsMetrics
//  The app's measurements, stated once: widths, padding, spacing, corner radii, sheet sizes.
//
//  A measurement typed at a call site belongs to whichever view was edited most recently, and
//  the copies drift. Twenty-four corner radii were typed out in eight values, with an
//  onboarding choice at 14 beside the glass cards at 16 and a migration step at 10, and the
//  sheets declared their sizes through two parameters, a raw `frame` and a hard-coded
//  minimum. Each token here names WHAT the measurement is for, so a change to "how round is a
//  card" is one line, and a view reading a token cannot disagree with its neighbour.
//
//  What is NOT here is a one-off: a chart's height, a glyph's point size, the width a single
//  picker happens to need. Those stay at their call site, because naming them would claim a
//  sameness nothing else shares. A one-off corner radius stays in the file of the one control
//  that has it, as a named constant saying what it is relative to (`FloatingBar`'s concentric
//  pair).
//
//  `DesignTokenPolicyTests` refuses a literal `cornerRadius:` number and a literal ideal
//  sheet size anywhere under `Views/` but here.

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
  /// Home stops widening at the same place a table does, for the same reason: it is a grid
  /// of cards that is meant to fill, and at 760 points a chart beside a list becomes a chart
  /// above a list, twice as far down the page.
  static let maximumDashboardWidth: CGFloat = 1100
  static let sectionSpacing: CGFloat = 26
  /// How close two glass cards may sit before `GlassGroup` fuses them into one shape. Below
  /// the tightest card gap in the app (Home's tiles, 12), so no grid ever merges.
  static let glassMergeDistance: CGFloat = 4
  static let cardPadding: CGFloat = 22
  static let rowSpacing: CGFloat = 20
  /// Controls line up at a common width so a column of them does not look ragged. A
  /// control with a fixed size of its own opts out (`SettingsRow.controlWidth`), because
  /// reserving width it cannot fill only narrows the explanation beside it.
  static let controlWidth: CGFloat = 320

  // MARK: - Inside a card

  /// The gap between the blocks a card stacks: its title, a paragraph, a row of controls, a
  /// list. `TitledCard` uses it, and so does every card that stacks its own; the titled
  /// cards had used 6, 8 and 10 with nothing to choose between them.
  static let cardStackSpacing: CGFloat = 12
  /// The width of the symbol leading a row in a list, so the text after it starts at one x
  /// whatever the symbol: `person.3.fill` is wider than `person.fill`, and a list without a
  /// fixed column starts its names at two different places.
  static let iconColumnWidth: CGFloat = 22

  // MARK: - Corner radii

  /// A card: `GlassCard`, `ContentCard`, a settings section. A card on Home and a card on a
  /// settings page are visibly the same object because they share this.
  static let cardCornerRadius: CGFloat = 16
  /// A surface smaller than a card that stands on its own rather than inside one's content:
  /// a drop zone, an onboarding choice, a migration step.
  static let tileCornerRadius: CGFloat = 12
  /// A field, or a block, inside a card: a text box, a search box, a box of results, a block
  /// of monospaced text, a table clipped to the card around it, a chart's placeholder.
  static let fieldCornerRadius: CGFloat = 8
  /// The highlight behind one row of a list: hover, selection, the current step. The same
  /// value as a field, and a separate token because it is a different thing that could
  /// change on its own; a highlight inset inside a field subtracts the inset from this
  /// (`ConversationRow`), so its corners stay concentric with the box around it.
  static let rowCornerRadius: CGFloat = 8
}

/// The size a sheet opens at, and the smallest it can be dragged to.
///
/// A sheet declares a minimum and an IDEAL, never a fixed size, so a person can make one
/// larger under a bigger text size; the minimum is what keeps the footer reachable. Named by
/// what the sheet holds rather than by its numbers, because the numbers had drifted: widths of
/// 560, 620 and 640 and heights of 460 and 480 for no reason any file gave.
///
/// The main window's minimum height is set by the tallest of these (`onboarding`), because a
/// sheet taller than its window draws its footer off the bottom, out of reach.
struct SheetSize: Equatable {
  let ideal: CGSize
  let minimum: CGSize

  /// What a `SheetScaffold` may shrink to.
  static let scaffoldMinimum = CGSize(width: 520, height: 440)

  /// A form of several sections: composing a scheduled message, editing a webhook.
  static let form = SheetSize(ideal: CGSize(width: 640, height: 660))
  /// One service's settings, or one record to read: `ConfigureSheet`, the audit inspector.
  static let detail = SheetSize(ideal: CGSize(width: 640, height: 560))
  /// A few rows and nothing that scrolls far: the HTTP listener.
  static let short = SheetSize(ideal: CGSize(width: 640, height: 460))
  /// A single question with a short answer: the Firebase setup prompts.
  static let prompt = SheetSize(ideal: CGSize(width: 560, height: 460))
  /// The migration wizard, a list of steps with its own chrome.
  static let migration = SheetSize(
    ideal: CGSize(width: 720, height: 560), minimum: CGSize(width: 600, height: 460))
  /// Onboarding, a rail beside the step: the tallest sheet in the app.
  static let onboarding = SheetSize(
    ideal: CGSize(width: 900, height: 640), minimum: CGSize(width: 820, height: 560))

  init(ideal: CGSize, minimum: CGSize = SheetSize.scaffoldMinimum) {
    self.ideal = ideal
    self.minimum = minimum
  }
}

extension View {
  /// Frames a sheet's root view at `size`: its minimum and its ideal, never a fixed size.
  func sheetFrame(_ size: SheetSize) -> some View {
    frame(
      minWidth: size.minimum.width, idealWidth: size.ideal.width,
      minHeight: size.minimum.height, idealHeight: size.ideal.height)
  }
}
