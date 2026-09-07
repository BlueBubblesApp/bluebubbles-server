//  CommunityLinks
//  Documentation, Discord and Donate, in the toolbar beside the notification bell.
//
//  The Electron UI carried six of these — Website Home, BlueBubbles Web, Sponsor Us, Support
//  Us, Discord and GitHub. Three is a deliberate trim rather than an oversight: the two site
//  links and the GitHub link go where the docs link already leads, and a toolbar row of six
//  identical grey glyphs is a row nobody reads. What survives is the three a user actually
//  leaves the app for — how do I do this, where do I ask, and how do I support it.
//
//  URLs are transcribed from `packages/ui/src/app/containers/navigation/Navigation.tsx` rather
//  than typed from memory. `discord.gg/yC4wr38` in particular is an invite code that cannot be
//  guessed or checked by eye, and a wrong one is a dead end that looks like a working button.
//
//  See `.claude/docs/architecture.md`.

import SwiftUI

struct CommunityLink: Identifiable, Sendable {
  let id: String
  let title: String
  let symbol: String
  let url: URL

  /// The three, in the order they appear.
  ///
  /// Docs first because it is the one with an answer in it; donate last because a support
  /// link that leads the row reads as a nag.
  static let all: [CommunityLink] = [
    .init(
      id: "docs", title: "Documentation", symbol: "book",
      url: URL(string: "https://docs.bluebubbles.app")!
    ),
    .init(
      id: "discord", title: "Join our Discord", symbol: "bubble.left.and.bubble.right",
      url: URL(string: "https://discord.gg/yC4wr38")!
    ),
    .init(
      id: "donate", title: "Support BlueBubbles", symbol: "heart",
      url: URL(string: "https://bluebubbles.app/donate")!
    ),
  ]
}

/// The toolbar row.
///
/// `Button` + `openURL` rather than `Link`, which is what these were first. A `Link` is the
/// more semantic control and it loses two things that matter more here: it renders in the
/// accent colour while every other toolbar control is monochrome, and it gets no hover
/// highlight, so three of the four controls in the group lit up on hover and these did not.
/// Matching the notification bell — a plain `Button` with an `Image` label — gets both back.
///
/// The pointer cursor is added explicitly. macOS gives a link cursor to a real `Link` and
/// nothing to a `Button`, and these still leave the app, so the cursor should say so.
struct CommunityLinks: View {

  @Environment(\.openURL) private var openURL

  var body: some View {
    ForEach(CommunityLink.all) { link in
      Button {
        openURL(link.url)
      } label: {
        Image(systemName: link.symbol)
      }
      .help(link.title)
      .accessibilityLabel(link.title)
      .linkCursor()
    }
  }
}

extension View {
  /// A pointing-hand cursor on hover.
  ///
  /// `pointerStyle(_:)` is the modern spelling and is macOS 15+, which is above this app's
  /// macOS 14 floor — so the older path is a real fallback rather than dead code.
  ///
  /// The fallback pushes and pops rather than calling `NSCursor.pointingHand.set()`:
  /// `set()` leaves the cursor changed when the pointer exits over a view that does not set
  /// it back, which strands a pointing hand over the rest of the window.
  @ViewBuilder
  fileprivate func linkCursor() -> some View {
    if #available(macOS 15.0, *) {
      self.pointerStyle(.link)
    } else {
      self.onHover { inside in
        if inside {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    }
  }
}
