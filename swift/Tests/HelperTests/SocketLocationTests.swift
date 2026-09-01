//  SocketLocationTests
//
//  The server and the injected helper derive the socket path independently, because there is
//  no channel to negotiate over yet. That only works if they derive the SAME path — and they
//  did not.
//
//  Messages.app is sandboxed, so inside it both `NSHomeDirectory()` and
//  `FileManager.urls(for: .applicationSupportDirectory)` return container-relative paths. The
//  helper computed a socket under `~/Library/Containers/com.apple.MobileSMS/…` while the
//  server — not sandboxed — created the real one. The helper connected to nothing, retried
//  forever, and said nothing about it.
//
//  This was measured, not deduced: the dylib was confirmed mapped into Messages with `vmmap`
//  while the server showed no connection at all.

import Darwin
import Foundation
import Testing

@testable import BBPrivateAPIContract

@Suite("SocketLocation")
struct SocketLocationTests {

  /// `getpwuid` reads the passwd database directly and is not redirected by a container,
  /// which is the whole reason it is used instead of the Foundation APIs.
  @Test("the home directory comes from the passwd database")
  func realHome() {
    let home = SocketLocation.realHomeDirectory
    #expect(home.hasPrefix("/"))
    #expect(!home.isEmpty)
    // Never inside a sandbox container — that is precisely the bug.
    #expect(!home.contains("/Library/Containers/"))
  }

  /// The socket lives INSIDE Messages' container, and that is the load-bearing part.
  ///
  /// The sandbox refuses a connect to a Unix socket outside the container — measured by
  /// injecting a probe into Messages, where the server's own Application Support directory
  /// and `/tmp` both returned EPERM and the container path connected. Moving this back
  /// breaks the Private API for everyone, silently, because the helper's only symptom is a
  /// retry loop.
  @Test("the socket lives inside Messages' container")
  func socketPath() {
    let path = SocketLocation.privateAPISocket
    #expect(path.hasSuffix("/private-api.sock"))
    #expect(path.contains("/Library/Containers/com.apple.MobileSMS/Data"))
    #expect(!path.contains("/Library/Application Support/BlueBubbles"))
  }

  /// `sun_path` is a fixed 104-byte field, and an over-long path is TRUNCATED rather than
  /// rejected — the server would bind one path and the helper connect to another, with
  /// neither reporting anything wrong. The container path is long, so this has to be
  /// checked rather than assumed.
  @Test("the socket path fits in sun_path")
  func socketPathFits() {
    #expect(SocketLocation.isUsableSocketPath(SocketLocation.privateAPISocket))
  }

  @Test("an unusable socket path is rejected")
  func unusablePathRejected() {
    #expect(!SocketLocation.isUsableSocketPath(""))
    #expect(
      !SocketLocation.isUsableSocketPath(
        "/Users/" + String(repeating: "a", count: 200) + "/x.sock"
      ))
  }

  /// The container is derived from the REAL home, not from `NSHomeDirectory()`.
  ///
  /// Inside Messages those two are the same string, and outside it they are not — so a
  /// helper using `NSHomeDirectory()` and a server using the real home would agree by
  /// accident in one direction and disagree in the other. Both go through `getpwuid`.
  @Test("the container is derived from the real home")
  func containerFromRealHome() {
    #expect(SocketLocation.messagesContainer.hasPrefix(SocketLocation.realHomeDirectory))
    #expect(
      SocketLocation.messagesContainer
        .hasSuffix("/Library/Containers/com.apple.MobileSMS/Data"))
  }

  @Test("the support directory is under the real home")
  func supportDirectory() {
    #expect(SocketLocation.supportDirectory.hasPrefix(SocketLocation.realHomeDirectory))
  }

  /// Both sides honour the same override, so a development server and its helper can be
  /// pointed somewhere else together.
  @Test("the socket path is overridable")
  func override() {
    // Read from the environment at call time rather than cached, which is what makes the
    // override usable at all — the helper is loaded before anything could configure it.
    let current = ProcessInfo.processInfo.environment["BLUEBUBBLES_HELPER_SOCKET"]
    #expect(current == nil || SocketLocation.privateAPISocket == current)
  }
}
