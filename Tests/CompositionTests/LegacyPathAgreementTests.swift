//  LegacyPathAgreementTests
//  The four call sites that name `~/Library/Application Support/bluebubbles-server` agree.
//
//  They did not, in a way nothing could see. `AppDatabase.defaultURL` and the Electron
//  config-database path resolved through `FileManager.homeDirectoryForCurrentUser`, while
//  `CertificateStore.defaultDirectory` and the Firebase credential paths used
//  `NSHomeDirectory()`. Those return the same string only while this app is unsandboxed
//  (`Packaging/BlueBubbles.entitlements` says it is, and why), under a container
//  `NSHomeDirectory()` is container-relative, and the migration would then read settings
//  from one directory and certificates from another with nothing reporting a problem.
//
//  This is the test that would have caught it, and it lives here because it is the only
//  module that can see all four owners at once.

import BBCore
import BBPersistence
import BBPushKit
import BBSettings
import BBSystem
import Foundation
import Testing

@Suite("Application Support agreement")
struct LegacyPathAgreementTests {

  @Test("Every owner resolves to the one directory")
  func oneDirectory() {
    let expected = ApplicationSupport.directory.standardizedFileURL.path

    #expect(AppDatabase.defaultURL.deletingLastPathComponent().standardizedFileURL.path == expected)
    #expect(
      LegacyConfigMigration.legacyDatabaseURL.deletingLastPathComponent()
        .standardizedFileURL.path == expected)
    #expect(
      CertificateStore.defaultDirectory.deletingLastPathComponent()
        .standardizedFileURL.path == expected)

    // The credential paths are Strings, and sit one level down in `FCM/`.
    let credentials = PushCredentialMigration.legacyPaths()
    for path in [credentials.serviceAccount, credentials.clientConfig] {
      let firebase = URL(fileURLWithPath: path).deletingLastPathComponent()
      #expect(firebase.lastPathComponent == "FCM")
      #expect(firebase.deletingLastPathComponent().standardizedFileURL.path == expected)
    }
  }

  /// The whole point of the injection: a test can ask about a directory that is definitely
  /// empty, rather than about whatever the machine running the suite happens to have.
  @Test("The credential paths can be pointed somewhere else")
  func credentialsAreInjectable() {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-agreement-\(UUID().uuidString)", isDirectory: true)
    let paths = PushCredentialMigration.legacyPaths(in: base)

    #expect(paths.serviceAccount.hasPrefix(base.path))
    #expect(paths.clientConfig.hasPrefix(base.path))
    #expect(PushCredentialMigration.hasLegacyCredentials(in: base) == false)
  }
}
