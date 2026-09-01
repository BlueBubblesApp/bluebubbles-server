//  SocketLocation
//  Where the server listens and the helper connects.
//
//  Both sides derive this rather than negotiating, because there is no channel to negotiate
//  over yet. That only works if they derive the SAME path — and they once did not.
//
//  **The socket lives inside Messages.app's container, and that is load-bearing.**
//
//  Messages is sandboxed (`com.apple.security.app-sandbox`), and the sandbox refuses a
//  `connect` to a Unix socket OUTSIDE its container. That was originally read as "the sandbox
//  refuses Unix sockets", and the server fell back to a loopback TCP bridge — which works,
//  and which cannot identify its peer, so any local process could drive the Private API.
//
//  Measured by injecting a probe into Messages, the refusal is about location, not about Unix
//  sockets:
//
//      ~/Library/Application Support/BlueBubbles/...   EPERM
//      /tmp/...                                        EPERM
//      <Messages container>/private-api.sock           CONNECTED
//
//  Inside the container it connects, and the connection carries `LOCAL_PEERTOKEN` — so the
//  server can verify the peer really is Messages, by audit token, with no TOCTOU window. A
//  process that is not Messages cannot satisfy that, and cannot reach the socket in the first
//  place. See `.claude/docs/private-api.md`.
//
//  Two consequences worth stating:
//
//    - The server writes into another application's container, which requires Full Disk
//      Access. The server already needs it to read chat.db, so this is not a new prompt —
//      but the Private API now depends on it where it did not before.
//    - `NSHomeDirectory()` is CONTAINER-RELATIVE inside Messages and absolute outside it, so
//      the two sides would compute different paths from it. `getpwuid` is not redirected,
//      which is why both go through it. That exact bug once had the helper connecting to a
//      path that did not exist, retrying forever, reporting nothing.

import Darwin
import Foundation

public enum SocketLocation {

  /// The user's REAL home directory, container redirection or not.
  ///
  /// Falls back to `NSHomeDirectory()` only if the passwd lookup fails, which would mean
  /// something is very wrong with the account — and a wrong path is a better failure than
  /// a crash.
  public static var realHomeDirectory: String {
    if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
      return String(cString: directory)
    }
    return NSHomeDirectory()
  }

  /// The directory holding the server's runtime state.
  public static var supportDirectory: String {
    realHomeDirectory + "/Library/Application Support/BlueBubbles"
  }

  /// A sandboxed app's container data directory.
  public static func container(for bundleIdentifier: String) -> String {
    realHomeDirectory + "/Library/Containers/\(bundleIdentifier)/Data"
  }

  /// Messages.app's sandbox container.
  public static var messagesContainer: String { container(for: HelperHost.messages) }

  /// FaceTime.app's sandbox container.
  public static var faceTimeContainer: String { container(for: HelperHost.faceTime) }

  /// The socket a helper injected into `bundleIdentifier` connects to.
  ///
  /// **ONE SOCKET CANNOT SERVE TWO APPS**, and assuming it could cost a long debugging
  /// session. The sandbox restriction documented above is SYMMETRIC — measured with both
  /// helpers injected and the server binding one path at a time:
  ///
  ///     socket in Messages' container   Messages connects; FaceTime never does
  ///     socket in FaceTime's container  FaceTime connects; Messages registers, then drops
  ///
  /// So the per-process routing on a single socket could never work: whichever app did not
  /// own the container was silently absent, and every untargeted action was answered by the
  /// wrong helper with `unknown action`. The server binds ONE SOCKET PER APP, and each
  /// helper connects to the one inside its own container.
  public static func privateAPISocket(for bundleIdentifier: String) -> String {
    if let override = ProcessInfo.processInfo.environment["BLUEBUBBLES_HELPER_SOCKET"],
      !override.isEmpty
    {
      return override
    }
    return container(for: bundleIdentifier) + "/private-api.sock"
  }

  /// The Messages socket. Kept as the unqualified name because it is the original location
  /// and the one a single-helper install uses.
  public static var privateAPISocket: String { privateAPISocket(for: HelperHost.messages) }

  /// Every socket the SERVER listens on — one per app it injects into.
  ///
  /// An explicit `BLUEBUBBLES_HELPER_SOCKET` collapses this to that single path, so a test
  /// or a development server can still point everything at one temporary location.
  public static var privateAPISockets: [String] {
    if let override = ProcessInfo.processInfo.environment["BLUEBUBBLES_HELPER_SOCKET"],
      !override.isEmpty
    {
      return [override]
    }
    return [HelperHost.messages, HelperHost.faceTime].map(privateAPISocket(for:))
  }

  /// `sun_path` is a fixed 104-byte field, and a path that does not fit is TRUNCATED rather
  /// than rejected — so the server binds one path, the helper connects to another, and
  /// neither reports anything wrong.
  ///
  /// A default install has ~25 bytes of headroom; a long user name or a network home eats
  /// it. Checked explicitly so the failure is a sentence rather than a silent mismatch.
  public static let maximumSocketPathLength = 103

  public static func isUsableSocketPath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= maximumSocketPathLength
  }
}
