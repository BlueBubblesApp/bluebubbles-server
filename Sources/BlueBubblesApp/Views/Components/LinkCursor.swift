//  LinkCursor
//  A pointing-hand cursor on hover.
//
//  Its own file because it has a second call site. It was `fileprivate` in
//  `CommunityLinks.swift`, and the row on the Firebase page that navigates to the registered
//  devices wants the same signal: the rule in `Sources/BlueBubblesApp/CLAUDE.md` is that a
//  shape drawn twice is standardised rather than copied, and a hand-rolled second copy of
//  the `#available` fallback below is exactly the kind that drifts.

import AppKit
import SwiftUI

extension View {
  /// A pointing-hand cursor on hover.
  ///
  /// `pointerStyle(_:)` is the modern spelling and is macOS 15+, which is above this app's
  /// macOS 14 floor, so the older path is a real fallback rather than dead code.
  ///
  /// The fallback pushes and pops rather than calling `NSCursor.pointingHand.set()`:
  /// `set()` leaves the cursor changed when the pointer exits over a view that does not set
  /// it back, which strands a pointing hand over the rest of the window.
  @ViewBuilder
  func linkCursor() -> some View {
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
