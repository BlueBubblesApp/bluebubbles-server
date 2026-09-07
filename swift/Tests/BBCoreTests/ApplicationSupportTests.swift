//  ApplicationSupportTests
//  One directory, one home-directory API, and an override that makes the rest testable.
//
//  The paths under `~/Library/Application Support/bluebubbles-server` were written out in
//  four files through TWO different home-directory APIs — `homeDirectoryForCurrentUser` in
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
}
