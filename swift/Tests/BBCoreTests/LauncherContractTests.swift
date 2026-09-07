//  LauncherContractTests
//  The intent file, and the one direction it must fail in.
//
//  The launcher reads this AFTER the app is gone, so nothing can be asked or retried. Every
//  ambiguous case therefore has to resolve to `.supervise` — a missing file, an empty one, a
//  value written by a newer build, a truncated write. The cost of guessing `.supervise` wrongly
//  is an app that comes back when the user meant to quit; the cost of guessing `.quit` wrongly
//  is a server that stays down after a crash and tells nobody. Those are not equivalent.

import Foundation
import Testing

@testable import BBCore

@Suite("Launcher contract")
struct LauncherContractTests {

  /// A directory of this test's own.
  ///
  /// Deliberately NOT `BB_SUPPORT_DIRECTORY`. That override is process-global and
  /// swift-testing runs suites in parallel, so setting it redirects every other suite running
  /// at that instant — which is exactly what happened: `ApplicationSupportTests` began failing
  /// intermittently, asserting real paths against a temp directory this suite had set. A
  /// `.serialized` trait does not help, because it orders tests WITHIN a suite and says
  /// nothing about the ones running beside it.
  private func inTemporaryDirectory(_ body: (URL) throws -> Void) rethrows {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-launcher-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try body(base)
  }

  @Test("An intent round-trips")
  func roundTrip() throws {
    try inTemporaryDirectory { base in
      for intent in [LauncherContract.Intent.quit, .restart, .supervise] {
        LauncherContract.writeIntent(intent, in: base)
        #expect(LauncherContract.readIntent(in: base) == intent)
      }
    }
  }

  @Test("No file at all means supervise")
  func absentMeansSupervise() throws {
    try inTemporaryDirectory { base in
      #expect(LauncherContract.readIntent(in: base) == .supervise)
    }
  }

  /// A crash writes nothing, so whatever was there last is what the launcher sees. This is the
  /// property the whole design rests on: the resting value has to be the one that restarts.
  @Test("A value that cannot be understood means supervise")
  func unreadableMeansSupervise() throws {
    try inTemporaryDirectory { base in
      for junk in ["", "   ", "nonsense", "QUIT", "supervise\n\nextra"] {
        try junk.write(to: LauncherContract.intentURL(in: base), atomically: true, encoding: .utf8)
        #expect(
          LauncherContract.readIntent(in: base) == .supervise,
          "\(junk.debugDescription) must not read as a reason to stay down")
      }
    }
  }

  /// Trailing whitespace is the realistic corruption — an editor, a shell redirect, a partial
  /// flush — and it must not turn a deliberate quit into a restart loop.
  @Test("Surrounding whitespace does not change the meaning")
  func whitespaceIsTolerated() throws {
    try inTemporaryDirectory { base in
      try "  quit\n".write(
        to: LauncherContract.intentURL(in: base), atomically: true, encoding: .utf8)
      #expect(LauncherContract.readIntent(in: base) == .quit)
    }
  }

  /// The launcher is found by path, not by asking LaunchServices for the identifier, so the
  /// path is part of the contract and matches what `build-app.sh` assembles.
  @Test("The bundle path is the one SMAppService reads")
  func bundlePathIsTheDocumentedOne() {
    #expect(
      LauncherContract.launcherBundlePath
        == "Contents/Library/LoginItems/BlueBubblesLauncher.app")
    #expect(
      LauncherContract.launcherBundleIdentifier.hasPrefix(
        LauncherContract.mainBundleIdentifier),
      "the launcher is a child identifier of the app it supervises")
  }
}
