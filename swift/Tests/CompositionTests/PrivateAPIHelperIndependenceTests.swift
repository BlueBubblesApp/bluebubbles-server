//  PrivateAPIHelperIndependenceTests
//  The two injected helpers are independent, and a settings change must treat them that way.
//
//  `PrivateAPIGatedService` owns BOTH the Messages helper and the FaceTime helper, only
//  because they share a transport. They are separate dylibs, in separate apps, on separate
//  sockets. Its `apply(_:)` returned `.restart` for any watched key, which made the registry
//  stop and start the whole service and re-inject both, so a FaceTime-only setting quit and
//  relaunched the user's Messages.app. Injection terminates somebody's app; doing it to the
//  wrong one as a side effect is the defect these tests pin.
//
//  The key GROUPING is what is asserted here, because it is the part a future setting gets
//  wrong: adding a FaceTime key to the Messages set is invisible until someone notices their
//  Messages restarting. The re-injection itself needs a live `PrivateAPIRuntime` and a Mac
//  with SIP off, so it is verified by hand; see docs/headers/FACETIME.md.

import BBSettings
import Testing

@testable import BlueBubblesServerCore

@Suite("Private API helper independence")
struct PrivateAPIHelperIndependenceTests {

  @Test("Every watched key belongs to exactly one helper")
  func keysArePartitioned() {
    let messages = PrivateAPIGatedService.messagesKeys
    let faceTime = PrivateAPIGatedService.faceTimeKeys

    #expect(
      messages.isDisjoint(with: faceTime),
      """
      A key in both sets re-injects both apps, which is the behaviour these sets exist to \
      prevent.
      """)
    #expect(!messages.isEmpty)
    #expect(!faceTime.isEmpty)
  }

  @Test("The FaceTime idle-camera switch is a FaceTime key and nothing else")
  func idleCameraIsFaceTimeOnly() {
    #expect(PrivateAPIGatedService.faceTimeKeys.contains(Settings.faceTimeIdleCameraOff.key))
    #expect(!PrivateAPIGatedService.messagesKeys.contains(Settings.faceTimeIdleCameraOff.key))
  }

  @Test("Enabling either helper is grouped with the app it injects")
  func enableSwitchesAreGrouped() {
    #expect(PrivateAPIGatedService.messagesKeys.contains(Settings.enablePrivateAPI.key))
    #expect(PrivateAPIGatedService.faceTimeKeys.contains(Settings.enableFaceTimePrivateAPI.key))
    #expect(PrivateAPIGatedService.messagesKeys.contains(Settings.privateAPIHelperPath.key))
    #expect(
      PrivateAPIGatedService.faceTimeKeys.contains(Settings.privateAPIFaceTimeHelperPath.key))
  }

  /// The manifest is what the registry routes a change on. A key the service partitions but
  /// the manifest does not declare never reaches `apply(_:)` at all: the service would be
  /// silently unreachable for that setting, which is how `enable_ft_private_api` would look
  /// if someone added a key to one place and not the other.
  @Test("Every partitioned key is declared on the manifest the registry watches")
  func partitionMatchesTheManifest() {
    let watched = PrivateAPIGatedService.watchedSettings
    for key in PrivateAPIGatedService.messagesKeys.union(PrivateAPIGatedService.faceTimeKeys) {
      #expect(watched.contains(key), "\(key) is partitioned but not watched")
    }
  }
}
