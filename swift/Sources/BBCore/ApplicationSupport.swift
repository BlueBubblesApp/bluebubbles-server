//  ApplicationSupport
//  Every path under `~/Library/Application Support/bluebubbles-server`, in one place.
//
//  This directory is shared with the Electron server — deliberately, because that is what
//  makes an upgrade find the user's certificates and configuration where they already are.
//  So it holds both this server's own state (`app.db`) and the artifacts an older install
//  left behind (`config.db`, `FCM/`, `Certs/`), and the migration has to reason about both.
//
//  Why one type. The same literal was written out in four files, through TWO different
//  home-directory APIs: `AppDatabase.defaultURL` and the config-database path used
//  `FileManager.homeDirectoryForCurrentUser`, while `CertificateStore.defaultDirectory` and
//  the FCM credential paths used `NSHomeDirectory()`. Those agree today only because this
//  app is not sandboxed (`Packaging/BlueBubbles.entitlements`) — under a container
//  `NSHomeDirectory()` is container-relative and the two answers diverge, which is exactly
//  the bug that once had the injected helper connecting to a socket path that did not
//  exist. Both now resolve through `getpwuid`, as `SocketLocation` already does and for the
//  same reason.
//
//  Why the override. Anything that reads these paths is otherwise untestable without
//  touching the developer's real installation — `PushWiringTests` had to branch on whether
//  the machine running the suite happened to have a service account on disk, which is a
//  test that asserts something different depending on who runs it. `BB_SUPPORT_DIRECTORY`
//  lets a test point the whole tree at a temporary directory instead.

import Darwin
import Foundation

public enum ApplicationSupport {

  /// The user's REAL home directory, container redirection or not.
  ///
  /// `getpwuid` reads the passwd database directly and is not redirected by a sandbox
  /// container. Falls back to `NSHomeDirectory()` only if the lookup fails, which would mean
  /// something is badly wrong with the account — and a wrong path fails more legibly than a
  /// crash.
  public static var realHomeDirectory: String {
    if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
      return String(cString: directory)
    }
    return NSHomeDirectory()
  }

  /// Overrides the whole tree, for tests. Never set in production.
  public static let overrideEnvironmentKey = "BB_SUPPORT_DIRECTORY"

  /// Whether the tree has been redirected away from the real installation.
  public static var isRedirected: Bool {
    !(ProcessInfo.processInfo.environment[overrideEnvironmentKey] ?? "").isEmpty
  }

  /// The Keychain service secrets are stored under.
  ///
  /// Derived from the override, and that is not a nicety — it is the thing that stops a
  /// redirected run touching the real installation's credentials. `BB_SUPPORT_DIRECTORY`
  /// redirects FILES; the Keychain is process-wide and global, so a migration pointed at a
  /// throwaway directory still wrote its `password` to the real service and overwrote the
  /// running server's password. That happened. A redirected run now gets its own service
  /// name, so the two cannot collide.
  public static var keychainService: String {
    let base = "app.bluebubbles.server"
    guard let override = ProcessInfo.processInfo.environment[overrideEnvironmentKey],
      !override.isEmpty
    else { return base }
    // FNV-1a rather than `hashValue`: Swift seeds String hashing PER PROCESS, so
    // `hashValue` would give a different service name on every run and a redirected run
    // could not read back what its previous run wrote.
    var digest: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in override.utf8 {
      digest ^= UInt64(byte)
      digest &*= 0x0000_0100_0000_01b3
    }
    return "\(base).redirected.\(String(digest, radix: 36))"
  }

  /// `~/Library/Application Support/bluebubbles-server`, or the override.
  public static var directory: URL {
    if let override = ProcessInfo.processInfo.environment[overrideEnvironmentKey],
      !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return URL(fileURLWithPath: realHomeDirectory, isDirectory: true)
      .appendingPathComponent("Library/Application Support/bluebubbles-server", isDirectory: true)
  }

  // MARK: - This server's own state

  /// The settings, device and access-control store.
  public static var appDatabase: URL { directory.appendingPathComponent("app.db") }

  // MARK: - What an older install left behind

  /// The Electron server's configuration database. Read-only to us, always.
  public static var electronConfigDatabase: URL {
    directory.appendingPathComponent("config.db")
  }

  /// Firebase credentials, which the Electron server stored in the clear.
  public static var electronFirebaseDirectory: URL {
    directory.appendingPathComponent("FCM", isDirectory: true)
  }

  public static var electronServiceAccount: URL {
    electronFirebaseDirectory.appendingPathComponent("server.json")
  }

  public static var electronClientConfig: URL {
    electronFirebaseDirectory.appendingPathComponent("client.json")
  }

  /// TLS material. NOT an Electron-only path — this server writes here too, which is why a
  /// file being present says nothing about whether an install is an upgrade.
  public static var certificates: URL {
    directory.appendingPathComponent("Certs", isDirectory: true)
  }
}
