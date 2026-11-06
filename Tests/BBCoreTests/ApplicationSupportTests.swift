//  ApplicationSupportTests
//  One directory, one home-directory API, and an override that makes the rest testable.
//
//  The paths under `~/Library/Application Support/bluebubbles-server` were written out in
//  four files through TWO different home-directory APIs: `homeDirectoryForCurrentUser` in
//  `AppDatabase` and the config-database path, `NSHomeDirectory()` in `CertificateStore` and
//  the Firebase credential paths. They agree while this app is unsandboxed and diverge the
//  moment it is not, which is the same class of bug that once had the injected helper
//  connecting to a socket path that did not exist.
//
//  `CompositionTests/LegacyPathAgreementTests` is the other half of this: it asserts the four
//  real call sites still land in one place. This file covers the type itself.

import Foundation
import Testing

@testable import BBCore

@Suite("Application Support paths")
struct ApplicationSupportTests {

  @Test("Every path hangs off one directory")
  func oneParent() {
    let base = ApplicationSupport.directory
    for url in [
      ApplicationSupport.appDatabase,
      ApplicationSupport.electronConfigDatabase,
      ApplicationSupport.electronFirebaseDirectory,
      ApplicationSupport.electronServiceAccount,
      ApplicationSupport.electronClientConfig,
      ApplicationSupport.certificates,
      ApplicationSupport.uploads,
      ApplicationSupport.convertedAttachments,
      ApplicationSupport.tools,
      ApplicationSupport.faceTimeLinks,
      ApplicationSupport.cloudflared,
      ApplicationSupport.tailscale,
    ] {
      #expect(url.path.hasPrefix(base.path), "\(url.lastPathComponent) is outside \(base.path)")
    }
  }

  /// The filenames are the Electron server's and are load-bearing: an upgrade finds a
  /// hand-installed certificate and an existing configuration only because these match.
  @Test("The names are the ones an older install wrote")
  func names() {
    #expect(ApplicationSupport.appDatabase.lastPathComponent == "app.db")
    #expect(ApplicationSupport.electronConfigDatabase.lastPathComponent == "config.db")
    #expect(ApplicationSupport.electronServiceAccount.lastPathComponent == "server.json")
    #expect(ApplicationSupport.electronClientConfig.lastPathComponent == "client.json")
    #expect(ApplicationSupport.certificates.lastPathComponent == "Certs")
    #expect(ApplicationSupport.directory.lastPathComponent == "bluebubbles-server")
  }

  /// `getpwuid` rather than `NSHomeDirectory()`, which a sandbox container redirects.
  @Test("The home directory comes from the passwd database")
  func realHome() {
    let home = ApplicationSupport.realHomeDirectory
    #expect(home.hasPrefix("/"))
    #expect(!home.isEmpty)
    #expect(!home.contains("/Library/Containers/"))
  }

  /// Not a convenience. Without it, anything reading these paths asserts something
  /// different depending on whether the machine running the suite has an Electron install.
  @Test("The override redirects the whole tree")
  func overrideIsHonoured() {
    #expect(ApplicationSupport.overrideEnvironmentKey == "BB_SUPPORT_DIRECTORY")
    // Asserted through the environment the process actually has: setting it here would be
    // process-global and these suites run in parallel. The injection points that matter
    // (`CertificateStore.init(directory:)`, `legacyPaths(in:)`) take a URL instead.
    let expected = ProcessInfo.processInfo.environment[ApplicationSupport.overrideEnvironmentKey]
    if let expected, !expected.isEmpty {
      #expect(ApplicationSupport.directory.path == expected)
    } else {
      #expect(
        ApplicationSupport.directory.path
          == ApplicationSupport.realHomeDirectory
          + "/Library/Application Support/bluebubbles-server")
    }
  }

  /// The half that was missing, and the only half that matters on a real install.
  ///
  /// `createDirectory(attributes:)` applies its attributes only to a directory it actually
  /// creates, so on every install after the first the mode is whatever it was made with —
  /// `0755`, because `AppDatabase.open` passes none. A test could not have caught that by
  /// creating a directory and checking it: the one a test makes is always new, and always
  /// passes. So this asserts the EXISTING case explicitly, by making a world-readable
  /// directory first.
  @Test("Hardening fixes a directory that already exists, not just one it creates")
  func hardeningIsAppliedToAnExistingDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-harden-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let before = try #require(
      FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)
    #expect(before.intValue & 0o077 != 0, "the test did not set up the case it is about")

    try ApplicationSupport.hardenDirectory(at: root)

    let after = try #require(
      FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)
    #expect(
      after.intValue & 0o077 == 0,
      "mode is \(String(after.intValue, radix: 8)), expected 0700")
  }

  @Test("Hardening creates a directory that is not there, already restricted")
  func hardeningCreatesRestricted() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-harden-new-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try ApplicationSupport.hardenDirectory(at: root)
    #expect(FileManager.default.fileExists(atPath: root.path))
    let mode = try #require(
      FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue & 0o077 == 0)
  }

  @Test("State a pre-release build kept beside the tree moves in once, and never over a copy")
  func legacyStateIsAdopted() throws {
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("adopt-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let legacy = scratch.appendingPathComponent("legacy", isDirectory: true)
    let root = scratch.appendingPathComponent("root", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: legacy.appendingPathComponent("moved.json"))
    try Data("old".utf8).write(to: legacy.appendingPathComponent("kept.json"))
    try Data("new".utf8).write(to: root.appendingPathComponent("kept.json"))

    let failures = ApplicationSupport.adopt(
      ["moved.json", "kept.json", "absent.json"], from: legacy, into: root)

    #expect(failures.isEmpty)
    #expect(try Data(contentsOf: root.appendingPathComponent("moved.json")) == Data("old".utf8))
    let left = legacy.appendingPathComponent("moved.json").path
    #expect(!FileManager.default.fileExists(atPath: left))
    // Already in place: the tree's copy wins and the old one is left where it was.
    #expect(try Data(contentsOf: root.appendingPathComponent("kept.json")) == Data("new".utf8))
    #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("kept.json").path))
  }
}
