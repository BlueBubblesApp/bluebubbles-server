//  HelperHostGuard
//  Whether a helper that has just been loaded is in the process it was written for.
//
//  A dylib constructor runs in whatever loads the dylib, and that is not only Messages or
//  FaceTime. `DYLD_INSERT_LIBRARIES` is inherited by every process the relaunched app
//  spawns; the package's test bundle links the Messages helper and so runs its constructor
//  in SwiftPM's discovery helper and in the test runner. Each of those would connect to the
//  live server's socket, present its own signature, and be refused: a warning in the server
//  log for every `swift test`, and a helper doing work inside a process it knows nothing
//  about. Refusing to start is the right answer in every one of those hosts.
//
//  The one exception is deliberate: a `BLUEBUBBLES_HELPER_SOCKET` override means a test or a
//  development server has pointed this helper at a socket of its own, and that is exactly a
//  host that is not the real app.

import Foundation

public enum HelperHostGuard {

  /// The environment variable that redirects the socket, and with it this check.
  public static let socketOverrideKey = "BLUEBUBBLES_HELPER_SOCKET"

  /// Whether a helper for `expected` should run in a process whose bundle identifier is
  /// `host`.
  public static func shouldRun(
    host: String?,
    expected: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    if host == expected { return true }
    if let override = environment[socketOverrideKey], !override.isEmpty { return true }
    return false
  }

  /// The current process's bundle identifier, as the guard sees it.
  public static var currentHost: String? { Bundle.main.bundleIdentifier }
}
