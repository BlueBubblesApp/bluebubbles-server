//  Branding
//  The product mark, and the one place that knows what it looks like.
//
//  Nothing on screen named the product. The Dock icon and the menu-bar item both do, and
//  neither is visible while someone is reading a page, so a screenshot of this app in a bug
//  report, or a support thread describing "the server window", carried no indication of what
//  it was. That is the gap this closes.
//
//  It lives in the SIDEBAR rather than on a page because the sidebar is the chrome that
//  survives navigation, the same reason `ServerStatusBar` is pinned to the foot of it. The
//  window title carries the name too (see `RootView`), which covers the one case the sidebar
//  does not: a user who has hidden it.
//
//  See `.claude/docs/architecture.md`.

import AppKit
import SwiftUI

enum Branding {

  static let name = "BlueBubbles"

  /// The marketing version, or nil.
  ///
  /// Optional rather than defaulted to something like "dev", because the only build with no
  /// `Info.plist` is a bare `swift run`, and printing a fake version number under the
  /// product name is worse than printing none. Read from the same key `CoreHandlers` and
  /// `UpdatesModel` read, so the three never disagree about what is running.
  static let version: String? =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

  /// The logo, decoded once.
  ///
  /// A `static let` and not a computed property: this is drawn in the sidebar, which
  /// re-renders on every navigation and on every server phase change, and `NSImage` from a
  /// URL re-reads the file each time it is constructed.
  ///
  /// The asset is a copy of `icons/regular/icon-128.png`: the bare bubble, not
  /// `icons/macos/dock-icon.png`, whose white rounded rectangle is drawn to sit in the Dock
  /// and reads as a card floating in the sidebar. It has to be COPIED in because SwiftPM
  /// resources must live inside the target directory; the bundle's own icon is still
  /// generated from `icons/` by `Packaging/build-app.sh`, so the two are separate reads of
  /// the same source art and a change to one is not a change to the other.
  static let logo: NSImage? = {
    guard
      let url = Bundle.module.url(forResource: "Branding/Logo", withExtension: "png"),
      let image = NSImage(contentsOf: url)
    else { return nil }
    // Named so `Image(nsImage:)` gets a stable identity across re-renders, and so the
    // accessibility layer has something better than "image" to fall back on.
    image.accessibilityDescription = "\(name) logo"
    return image
  }()
}

/// The logo at a given point size, with a fallback that is still recognisably a bubble.
///
/// The fallback is not decoration. `Bundle.module` resolves through `Bundle.main.resourceURL`
/// at runtime, so a bundle assembled without the resource bundles (the failure
/// `Packaging/build-app.sh` asserts against) would otherwise render an empty gap where the
/// product name is.
struct BrandLogo: View {

  var size: CGFloat = 28

  var body: some View {
    Group {
      if let logo = Branding.logo {
        Image(nsImage: logo).resizable()
      } else {
        Image(systemName: "bubble.left.fill")
          .resizable()
          .foregroundStyle(.tint)
      }
    }
    .aspectRatio(contentMode: .fit)
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// The mark at the head of the sidebar: logo, product name, and the version that is running.
///
/// The version sits here rather than only in the About panel because it is the first thing
/// asked for in a support thread, and "open the Apple menu, About BlueBubbles" is a round
/// trip that this makes unnecessary.
struct BrandHeader: View {

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 9) {
        BrandLogo(size: 30)
        VStack(alignment: .leading, spacing: 0) {
          Text(Branding.name)
            .font(.headline)
            .lineLimit(1)
          if let version = Branding.version {
            Text("Server \(version)")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }
      // The same horizontal inset `ServerStatusBar` uses, so the brand at the top and the
      // status at the bottom line up with each other rather than each with the list rows.
      .padding(.horizontal, 12)
      .padding(.top, 6)
      .padding(.bottom, 10)

      Divider()
    }
    // One element to VoiceOver. Read as three it announces "BlueBubbles, Server, 1.2.3" as
    // separate stops on the way to the navigation list, which is a lot of nothing to page
    // through before reaching the first thing you can act on.
    .accessibilityElement(children: .combine)
  }
}
