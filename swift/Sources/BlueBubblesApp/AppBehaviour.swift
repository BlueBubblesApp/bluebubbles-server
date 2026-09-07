//  AppBehaviour
//  The settings that act on the app and the Mac rather than on the server.
//
//  Dock icon, dock badge, start delay, start minimized, locking the screen, opening FindMy.
//  Six settings that had rows on the General page and no implementation anywhere — the server
//  read none of them, because none of them are the server's business. They belong to the app
//  process, which is why they ended up with nobody to own them.
//
//  Gathered here rather than scattered through views so the decisions can be tested. The
//  decisions are the part worth testing: `shouldLock` in particular reproduces a rule from the
//  Electron server that looks like a bug until you know why it is there.
//
//  See `.claude/docs/architecture.md`.

import AppKit
import BBSystem
import Foundation

/// The choices, separated from the side effects so they can be asserted.
enum AppBehaviourPolicy {

  /// The FindMy app's bundle identifier. Launching it is what refreshes the caches under
  /// `~/Library/Caches/com.apple.findmy.fmipcore` that `BBSystem.FindMy` reads.
  static let findMyBundleID = "com.apple.findmy"

  /// Whether to lock the screen now.
  ///
  /// Only within five minutes of boot, which is the Electron server's rule and is the whole
  /// point of the setting: it exists for a headless Mac that reboots — after a power cut, or
  /// an OS update — and comes back to an unlocked desktop. Without the uptime test the
  /// setting would lock the screen every time the server started, including when the person
  /// sitting in front of it pressed Start, which is why it reads as hostile if you meet it
  /// without the context.
  static func shouldLock(enabled: Bool, uptime: TimeInterval) -> Bool {
    enabled && uptime <= 300
  }

  /// How long to wait before starting services, clamped to the range the setting allows.
  ///
  /// Applied to an AUTOMATIC start only. A delay on a button press is a button that appears
  /// not to work; the setting exists so a login-item launch can let the network, VPN or
  /// external disk it depends on come up first.
  static func startDelay(_ configured: Double, isAutomatic: Bool) -> Duration? {
    guard isAutomatic, configured > 0 else { return nil }
    return .seconds(min(max(configured, 0), 600))
  }

  /// The dock badge text: `nil` hides it.
  ///
  /// Zero renders nothing rather than "0" — a permanent zero trains people to stop reading
  /// the badge, which is the same reasoning the sidebar badges use.
  static func badgeLabel(count: Int, enabled: Bool) -> String? {
    guard enabled, count > 0 else { return nil }
    return String(count)
  }
}

extension AppBehaviourPolicy {

  /// The activation policy for a given visibility, as a DECISION separate from the AppKit
  /// call that applies it — so the choice is testable without a running NSApplication.
  ///
  /// `.accessory`, never `.prohibited`: prohibited hides the Dock icon AND suppresses the
  /// menu bar, which left a headless server with no indication it was running at all.
  static func activationPolicy(dockHidden: Bool) -> NSApplication.ActivationPolicy {
    dockHidden ? .accessory : .regular
  }

  /// Headless is the same visual outcome as hiding the Dock icon: no icon, menu bar intact.
  static func activationPolicy(headless: Bool) -> NSApplication.ActivationPolicy {
    headless ? .accessory : .regular
  }
}

@MainActor
enum AppBehaviour {

  /// Shows or hides the Dock icon.
  ///
  /// `setActivationPolicy` rather than `NSApp.dockTile`/`dock.hide()`, for the reason the
  /// Electron server documents from experience: it is the runtime equivalent of `LSUIElement`
  /// and survives window creation, whereas hiding the dock tile is undone the next time a
  /// window appears.
  static func applyDockVisibility(hidden: Bool) {
    NSApp.setActivationPolicy(AppBehaviourPolicy.activationPolicy(dockHidden: hidden))
  }

  static func applyDockBadge(count: Int, enabled: Bool) {
    NSApp.dockTile.badgeLabel = AppBehaviourPolicy.badgeLabel(count: count, enabled: enabled)
  }

  /// Closes the main window, leaving the menu bar item behind.
  ///
  /// For the headless launch, which wants no window but must still be visible in the menu
  /// bar. The MenuBarExtra's own window is excluded — closing that would remove the status
  /// item, which is the one thing headless mode has to keep.
  static func closeMainWindow() {
    for window in NSApp.windows where window.canBecomeMain && window.isVisible {
      window.close()
    }
  }

  /// Minimises the main window, if there is one.
  ///
  /// Not `NSApp.hide`: hiding removes the app from view entirely, and someone who asked to
  /// start minimised still expects to find it in the Dock or the app switcher.
  static func minimizeMainWindow() {
    for window in NSApp.windows where window.isVisible && window.canBecomeMain {
      window.miniaturize(nil)
    }
  }

  /// Launches FindMy so it refreshes the caches the FindMy endpoints read.
  ///
  /// The data comes from files FindMy writes; without the app having run they are stale or
  /// absent, and the endpoints return nothing with no explanation.
  @discardableResult
  static func openFindMy() -> Bool {
    ApplicationControl.launch(bundleIdentifier: AppBehaviourPolicy.findMyBundleID)
  }

  /// How long this Mac has been up.
  static var systemUptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

// Locking the screen lives in `BBSystem.ScreenLock`, which this file already imports.
//
// There was a second copy here, and because a type declared in the module beats an
// imported one, it SHADOWED the real implementation for every caller inside the app —
// so "Lock Screen" from the UI and the same action over the HTTP API did different
// things. The copy resolved a different path inside login.framework, discarded the
// status the call returns, and had no `pmset displaysleepnow` fallback, which is the
// half that matters on a Mac without "require password after sleep": the private call
// is what actually locks, and without the fallback a failure looked like success.
