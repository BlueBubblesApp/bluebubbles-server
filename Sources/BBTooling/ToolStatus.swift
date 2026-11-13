//  ToolStatus
//  What the UI reads about a managed tool: `ToolOrigin`, `ToolActivity`, `ToolCopyOnThisMac`
//  and `ToolStatus`, the one value `ToolManager` publishes per tool.
//
//  Its own file so a view that renders a tool opens the shape it is handed and not the actor
//  that installs, reverts and checks for updates (`ToolManager.swift`). Nothing here acts;
//  every value is derived from a `ToolState` and a descriptor.

import BBServiceKit
import Foundation

/// Where the executable being used came from.
public enum ToolOrigin: String, Sendable, Equatable, Codable {
  /// Downloaded and managed here.
  case managed
  /// A binary the user pointed at: an offline install, or a copy they chose by hand.
  case external
  /// A copy that was already on this Mac when we looked, and that nobody chose.
  ///
  /// Kept apart from `external` because the difference decides behaviour, not just wording:
  /// an explicit choice is honoured even when the copy later drifts out of range (loudly),
  /// and this one is not, because the version test is the whole of its license to be used.
  case discovered
  /// Shipped inside the app bundle. The fallback, so a build that does bundle its binaries
  /// keeps working unchanged.
  case bundled
  case missing
}

public enum ToolActivity: Sendable, Equatable {
  case idle
  /// Asking the vendor whether something newer is published.
  case checking
  /// Probing copies already on this Mac, because somebody pressed Check Again.
  case lookingOnThisMac
  /// Probing a program somebody just chose by hand.
  case inspectingChosenCopy
  case installing(ToolInstallPhase)
  /// The last attempt failed, and this is what it said. Cleared by the next attempt.
  case failed(String)
}

/// What a scan found on this Mac, ready for a page to render.
///
/// Derived in `status(of:)` rather than stored, so that a range which moves when the server
/// updates re-judges an old recording instead of contradicting it. Lives here rather than on
/// a view because it is a decision, and a decision on a `View` cannot be tested.
public enum ToolCopyOnThisMac: Sendable, Equatable {
  /// This tool declares no compatible range, so a copy on this Mac is never adopted.
  case notConsidered
  case notLookedYet
  case none
  case usable(path: String, version: String)
  case incompatible(path: String, version: String, requirement: String)
  case unreadableVersion(path: String)

  /// The file this is about, when there is one.
  public var path: String? {
    switch self {
    case .notConsidered, .notLookedYet, .none: nil
    case .usable(let path, _), .incompatible(let path, _, _), .unreadableVersion(let path):
      path
    }
  }
}

public struct ToolStatus: Sendable, Equatable, Identifiable {
  public let descriptor: ManagedToolDescriptor
  public let state: ToolState
  public let activity: ToolActivity
  public let origin: ToolOrigin
  /// What a service would actually be handed right now.
  public let executablePath: String?
  /// A copy already on this Mac, judged against the range as of now.
  public let copyOnThisMac: ToolCopyOnThisMac
  /// Whether this tool may use a copy it did not install.
  public let preference: ToolPreference

  public var id: String { descriptor.id }
  public var installedVersion: String? { state.installed?.version }
  public var canRevert: Bool { state.previous != nil }
  /// The version this plugin says it works with, if it named one.
  public var recommendedVersion: String? { descriptor.recommended?.version }
  /// Whether what is installed is the version the plugin recommends.
  ///
  /// The state the UI leads with. "You are on the tested version" is the reassurance someone
  /// looking at this page wants, and a newer build existing does not change it.
  public var isOnRecommendedVersion: Bool {
    guard let recommended = descriptor.recommended else { return false }
    guard let installed = state.installed else { return false }
    return installed.version == recommended.version
  }
  /// A newer recommended version: the offer worth acting on.
  public var recommendedUpdate: AvailableUpdate? { state.recommendedUpdate }
  /// A newer build than the recommended one. Available, not advised.
  public var latestUpdate: AvailableUpdate? { state.latestUpdate }
  public var isBusy: Bool {
    switch activity {
    case .checking, .lookingOnThisMac, .inspectingChosenCopy, .installing: true
    case .idle, .failed: false
    }
  }
}
