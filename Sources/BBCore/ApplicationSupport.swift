//  ApplicationSupport
//  Every path under `~/Library/Application Support/bluebubbles-server`, in one place.
//
//  This directory is shared with the Electron server, deliberately, because that is what
//  makes an upgrade find the user's certificates and configuration where they already are.
//  So it holds both this server's own state (`app.db`) and the artifacts an older install
//  left behind (`config.db`, `FCM/`, `Certs/`), and the migration has to reason about both.
//
//  Why one type. Every path resolves the home directory the same way, through `getpwuid`,
//  as `SocketLocation` does and for the same reason. `NSHomeDirectory()` and
//  `FileManager.homeDirectoryForCurrentUser` agree only because this app is not sandboxed
//  (`Packaging/BlueBubbles.entitlements`); under a container `NSHomeDirectory()` is
//  container-relative and the two diverge, which is how an injected helper ends up
//  connecting to a socket path that does not exist. One resolution, in one place, keeps
//  every path on the same answer.
//
//  Why the override. Anything that reads these paths is otherwise untestable without
//  touching the developer's real installation. `BB_SUPPORT_DIRECTORY` lets a test point the
//  whole tree at a temporary directory instead.

import Darwin
import Foundation

public enum ApplicationSupport {

  /// The user's REAL home directory, container redirection or not.
  ///
  /// `getpwuid` reads the passwd database directly and is not redirected by a sandbox
  /// container. Falls back to `NSHomeDirectory()` only if the lookup fails, which would mean
  /// something is badly wrong with the account, and a wrong path fails more legibly than a
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
  /// Derived from the override, and that is not a nicety: it is the thing that stops a
  /// redirected run touching the real installation's credentials. `BB_SUPPORT_DIRECTORY`
  /// redirects FILES; the Keychain is process-wide and global, so a migration pointed at a
  /// throwaway directory would still write its `password` to the real service and overwrite
  /// the running server's password. A redirected run gets its own service name, so the two
  /// cannot collide.
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

  /// Creates a directory this server owns, and makes it `0700` whether or not it existed.
  ///
  /// **The second half is the part that matters.** `createDirectory(attributes:)` applies
  /// its attributes only to a directory it actually CREATES, so on every install that
  /// already has one — which is every install after the first run — the attribute is a
  /// no-op and the directory keeps whatever mode it was made with. Ours was made by
  /// `AppDatabase.open` with no attributes at all, so `0755`: world-readable, holding the
  /// push tokens, the blocklist, the Firebase credentials and the search index.
  ///
  /// `try?` on the mode: a directory we cannot chmod is one somebody has deliberately
  /// locked down, and refusing to start over it would be worse than leaving it alone.
  public static func hardenDirectory(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  /// `hardenDirectory` over the whole tree. Called once, at startup.
  public static func prepareOwnDirectory() throws {
    try hardenDirectory(at: directory)
  }

  // MARK: - This server's own state

  /// The settings, device and access-control store.
  public static var appDatabase: URL { directory.appendingPathComponent("app.db") }

  /// The message search index.
  ///
  /// **Its own file, deliberately, and not a table in `app.db`.** Three reasons, and the
  /// first is the one that decides it:
  ///
  ///   - It holds data derived from message text, and turning the feature off has to leave
  ///     nothing behind. Deleting a file is complete and checkable; `DELETE FROM` inside
  ///     `app.db` frees pages that still hold the old tokens until something vacuums.
  ///   - It is a CACHE. Every row in it can be rebuilt from `chat.db` in seconds, so it
  ///     must never be able to stop the server: a table declared through `SchemaContributor`
  ///     is created by `AppDatabase.open`, and a migration that throws there takes the whole
  ///     process down. An optional, rebuildable index has no business holding that power.
  ///   - The FTS5 options it needs are not available on every SQLite this server runs on.
  ///     As a separate file that is a feature which reports itself unavailable; as a
  ///     migration it would be a server that will not start.
  ///
  /// See `docs/SEARCH.md`.
  public static var searchIndex: URL { directory.appendingPathComponent("search-index.db") }

  /// Files a POST stages before they are sent. See `UploadStore`.
  public static var uploads: URL { directory.appendingPathComponent("uploads", isDirectory: true) }

  /// Attachments converted for a client that cannot read the original. See
  /// `AttachmentConversion`.
  public static var convertedAttachments: URL {
    directory.appendingPathComponent("ConvertedAttachments", isDirectory: true)
  }

  /// The external programs a connection method runs, and their records. See `ToolStore`.
  public static var tools: URL { directory.appendingPathComponent("Tools", isDirectory: true) }

  /// The FaceTime links this server minted, so it can invalidate them later.
  public static var faceTimeLinks: URL { directory.appendingPathComponent("facetime-links.json") }

  /// The empty configuration cloudflared is pointed at instead of its own default.
  public static var cloudflared: URL {
    directory.appendingPathComponent("cloudflared", isDirectory: true)
  }

  /// The embedded Tailscale node's state: its identity on the tailnet.
  public static var tailscale: URL {
    directory.appendingPathComponent("tailscale", isDirectory: true)
  }

  // MARK: - Where a pre-release build kept some of it

  /// `~/Library/Application Support/BlueBubbles`, which pre-release builds of this server
  /// used for the FaceTime ledger and the Tailscale node, beside the real tree rather than in
  /// it. Two roots meant a run redirected by `BB_SUPPORT_DIRECTORY` still read and wrote the
  /// real installation's tailnet identity. Read only by `adoptLegacyState`.
  ///
  /// The single-instance lock is in that folder too and STAYS there: see
  /// `SingleInstanceLock.defaultPath`.
  static var legacyStateDirectory: URL {
    URL(fileURLWithPath: realHomeDirectory, isDirectory: true)
      .appendingPathComponent("Library/Application Support/BlueBubbles", isDirectory: true)
  }

  /// What `adoptLegacyState` moves. The cloudflared folder is not on it: what it holds is
  /// rewritten on every start.
  static let legacyStateItems = ["facetime-links.json", "tailscale"]

  /// Moves what a pre-release build kept under `legacyStateDirectory` to its place in the
  /// tree, once: an item already in place is left alone, and so is the old copy.
  ///
  /// Never for a redirected run, which would otherwise take the real installation's state
  /// into a throwaway directory. Returns what could not be moved, for the caller to log; an
  /// item left behind costs the state it held (a tailnet sign-in, links that will not be
  /// invalidated) and never the start.
  public static func adoptLegacyState() -> [(item: String, error: any Error)] {
    guard !isRedirected else { return [] }
    return adopt(legacyStateItems, from: legacyStateDirectory, into: directory)
  }

  /// The move itself, over any two folders, so a test can run it without a real home.
  static func adopt(
    _ items: [String], from legacy: URL, into root: URL
  ) -> [(item: String, error: any Error)] {
    let files = FileManager.default
    var failures: [(item: String, error: any Error)] = []
    for item in items {
      let source = legacy.appendingPathComponent(item)
      let destination = root.appendingPathComponent(item)
      guard files.fileExists(atPath: source.path), !files.fileExists(atPath: destination.path)
      else { continue }
      do {
        try files.moveItem(at: source, to: destination)
      } catch {
        failures.append((item, error))
      }
    }
    return failures
  }

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

  /// TLS material. NOT an Electron-only path: this server writes here too, which is why a
  /// file being present says nothing about whether an install is an upgrade.
  public static var certificates: URL {
    directory.appendingPathComponent("Certs", isDirectory: true)
  }
}
