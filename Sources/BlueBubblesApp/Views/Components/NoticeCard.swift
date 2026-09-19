//  NoticeCard
//  A symbol, a headline, and the explanation under it.
//
//  Four screens had drawn this and no two agreed. The Private API prerequisite note and its
//  status card put the symbol beside the whole text block at the first baseline, ten points
//  apart, with `.callout` underneath; the Firebase summary put it inline with the title only
//  and used `.subheadline`; the contacts explainer was a third spelling again. The text sizes
//  differed, the spacings differed, and the symbol sat in a different place depending on which
//  screen you were looking at: for what is, on all four, the same sentence about the same
//  kind of thing.
//
//  This is that shape once. `Tag` was extracted for the same reason and the comment there says
//  it plainly: five pages had drawn their own at three paddings.
//
//  TONE IS A SEPARATE ARGUMENT FROM THE SYMBOL, and that is the point of having it. A notice
//  that explains how a feature works must not borrow the colour of one that reports a
//  problem: the Firebase page says so about itself, that an unconfigured server is a
//  supported deployment and there is no warning colour anywhere on the screen. Left to a
//  caller picking a `foregroundStyle` at each site, that distinction is one someone has to
//  remember; named, it is one they have to choose.
//
//  NOT the two notices next to this file. `ServerStoppedNotice` and `FeatureDisabledNotice`
//  answer one question each, carry their own buttons, and change container with placement:
//  they are instances of a notice, not a shape to draw one with. They keep their own files
//  and use this vocabulary rather than reproducing it.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import SwiftUI

/// What a notice is about, which decides its colour and nothing else.
enum NoticeTone {
  /// How something works. The default, and the one with no colour: a description is not a
  /// problem, and a page full of coloured symbols teaches people to ignore the coloured one
  /// that matters.
  case informational
  /// Working, confirmed. Sparingly: most things that work say nothing at all.
  case good
  /// Not broken, but waiting on a person or short of something.
  case attention
  /// Broken, and it will stay broken until somebody acts.
  case problem

  var tint: Color {
    switch self {
    case .informational: .secondary
    case .good: .green
    case .attention: .orange
    case .problem: .red
    }
  }
}

struct NoticeCard<Content: View, Accessory: View>: View {

  let symbol: String
  let title: String
  var tone: NoticeTone = .informational
  /// The explanation, one entry per paragraph. Styled here so two notices cannot disagree
  /// about how an explanation looks.
  var messages: [String] = []
  /// Anything below the paragraphs: a link, a row of tags, a button. Deliberately
  /// unstyled: a link that inherited secondary text colour would stop looking like a link.
  private let content: Content
  /// The trailing edge of the title row, for something about the notice itself rather than
  /// about what it says. A progress spinner is the case this exists for.
  private let accessory: Accessory

  init(
    symbol: String,
    title: String,
    tone: NoticeTone = .informational,
    messages: [String] = [],
    @ViewBuilder content: () -> Content,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.symbol = symbol
    self.title = title
    self.tone = tone
    self.messages = messages
    self.content = content()
    self.accessory = accessory()
  }

  init(
    symbol: String,
    title: String,
    tone: NoticeTone = .informational,
    messages: [String] = [],
    @ViewBuilder content: () -> Content
  ) where Accessory == EmptyView {
    self.init(
      symbol: symbol, title: title, tone: tone, messages: messages,
      content: content, accessory: { EmptyView() })
  }

  init(
    symbol: String,
    title: String,
    tone: NoticeTone = .informational,
    messages: [String] = []
  ) where Content == EmptyView, Accessory == EmptyView {
    self.init(
      symbol: symbol, title: title, tone: tone, messages: messages,
      content: { EmptyView() }, accessory: { EmptyView() })
  }

  var body: some View {
    GlassCard {
      NoticeBody(
        symbol: symbol, title: title, tone: tone, messages: messages,
        content: { content }, accessory: { accessory })
    }
  }
}

/// The same block without a card around it.
///
/// Separate because two callers own their own container: `FeatureDisabledNotice` is placed
/// inside a `GlassCard` the PAGE supplies, and `ServerStoppedNotice` changes container with
/// its placement. Rather than give the card a "draw no card" flag (which is the shape that
/// invites a third and a fourth) the block is the thing, and `NoticeCard` is the block in a
/// card.
struct NoticeBody<Content: View, Accessory: View>: View {

  let symbol: String
  let title: String
  var tone: NoticeTone = .informational
  var messages: [String] = []
  private let content: Content
  private let accessory: Accessory

  init(
    symbol: String,
    title: String,
    tone: NoticeTone = .informational,
    messages: [String] = [],
    @ViewBuilder content: () -> Content,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.symbol = symbol
    self.title = title
    self.tone = tone
    self.messages = messages
    self.content = content()
    self.accessory = accessory()
  }

  init(
    symbol: String,
    title: String,
    tone: NoticeTone = .informational,
    messages: [String] = [],
    @ViewBuilder content: () -> Content
  ) where Accessory == EmptyView {
    self.init(
      symbol: symbol, title: title, tone: tone, messages: messages,
      content: content, accessory: { EmptyView() })
  }

  init(
    symbol: String,
    title: String,
    tone: NoticeTone = .informational,
    messages: [String] = []
  ) where Content == EmptyView, Accessory == EmptyView {
    self.init(
      symbol: symbol, title: title, tone: tone, messages: messages,
      content: { EmptyView() }, accessory: { EmptyView() })
  }

  var body: some View {
    // The symbol beside the whole text column, aligned to the title's baseline, which is
    // what two of the four originals did and the one that survives a long explanation: put
    // inline with the title only, it drifts away from text that wraps under it.
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: symbol)
        .foregroundStyle(tone.tint)
        // The title says what the symbol says. Read out twice, it is noise on every
        // notice in the app.
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title).font(.headline)
          Spacer(minLength: 0)
          accessory
        }

        // `.callout` rather than `.subheadline`: it is what `SettingsRow` help text and
        // both Private API cards already use, so an explanation is the same size wherever
        // it appears.
        //
        // Identified by position, which is right here and nowhere near the rule about
        // rows: these are fixed paragraphs of one notice, not a list that inserts,
        // deletes or animates. Two identical paragraphs would collide under `\.self`.
        // NO `fixedSize`, AND THE BOUNDS BELOW ARE NOT COSMETIC. Together they are the
        // fix for a bug that took eight bisection builds to corner, so both are load
        // bearing and neither should be "tidied" back.
        //
        // What it did: on the Contacts page, the NavigationSplitView's sidebar rendered
        // nothing at all, no rows and no brand header and no status strip, while keeping
        // its full width, and the window title was drawn on top of the table's first rows.
        //
        // What it was: `fixedSize(vertical: true)` asks a paragraph to report its IDEAL
        // height. Ideal height depends on the width being proposed, and Contacts is the one
        // page that is not inside a scroll view, so nothing proposed one. An unbounded
        // paragraph resolves that as a very tall, very narrow block, and that height became
        // the column's top inset, which is what pushed the title onto the rows and the
        // sidebar's contents out of view.
        //
        // How it was established, since the mechanism is not visible from the code: a
        // bisection over nine variants of the page. Every configuration containing a notice
        // failed; the table alone passed, a plain label pinned above it passed, and a
        // width-capped search field pinned above it passed. It is the notice, and removing
        // this line with the bounds below is what fixed it.
        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
          Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        content
      }
      // BOUNDED BOTH WAYS, for the two halves of the same failure. See the note on the
      // paragraphs above.
      //
      // The ceiling stops the ideal WIDTH running away: `maxWidth: .infinity` below means
      // "take the width offered", and where nothing offers one SwiftUI asks for the ideal
      // instead, which for a paragraph is the whole sentence on one unwrapped line. 620 is
      // also the right measure for running text, so it is not a workaround wearing a
      // comment.
      //
      // The floor stops the opposite: proposed a very narrow width, wrapping text grows
      // tall without limit, and that height is what emptied a sidebar.
      .frame(minWidth: 260, maxWidth: 620, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
