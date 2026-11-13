//  HelperHostGuardTests
//  A helper runs in its own app, or where a test has pointed it, and nowhere else.

import HelperShared
import Testing

@Suite("Helper host guard")
struct HelperHostGuardTests {

  @Test("The intended app runs the helper; anything else does not")
  func hostMustMatch() {
    #expect(
      HelperHostGuard.shouldRun(
        host: "com.apple.MobileSMS", expected: "com.apple.MobileSMS", environment: [:]))
    #expect(
      !HelperHostGuard.shouldRun(
        host: "com.apple.FaceTime", expected: "com.apple.MobileSMS", environment: [:]))
    // SwiftPM's test discovery helper, which is where this was first seen connecting.
    #expect(
      !HelperHostGuard.shouldRun(
        host: "swiftpm-xctest-helper", expected: "com.apple.MobileSMS", environment: [:]))
    // A process with no bundle at all: a child that inherited the injection.
    #expect(
      !HelperHostGuard.shouldRun(host: nil, expected: "com.apple.MobileSMS", environment: [:]))
  }

  @Test("A socket override is a test or a development server, and runs anywhere")
  func overrideRunsAnywhere() {
    let redirected = [HelperHostGuard.socketOverrideKey: "/tmp/bb-test.sock"]
    #expect(
      HelperHostGuard.shouldRun(host: nil, expected: "com.apple.MobileSMS", environment: redirected)
    )
    // Set but empty is not set.
    let empty = [HelperHostGuard.socketOverrideKey: ""]
    #expect(
      !HelperHostGuard.shouldRun(host: nil, expected: "com.apple.MobileSMS", environment: empty))
  }

  /// The hard guard in front of TelephonyUtilities, which traps outside FaceTime.app. A test
  /// that set the socket override is precisely a process that is not FaceTime, so the
  /// override that lets a helper START there must not let it reach those calls.
  @Test("The hard host check has no override")
  func hardCheckIgnoresTheOverride() {
    #expect(HelperHostGuard.isRunning(in: "com.apple.FaceTime", host: "com.apple.FaceTime"))
    #expect(!HelperHostGuard.isRunning(in: "com.apple.FaceTime", host: "com.apple.MobileSMS"))
    #expect(!HelperHostGuard.isRunning(in: "com.apple.FaceTime", host: nil))
    // This test process: not FaceTime, whatever its environment says.
    #expect(!HelperHostGuard.isRunning(in: "com.apple.FaceTime"))
  }
}
