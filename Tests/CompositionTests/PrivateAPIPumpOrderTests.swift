//  PrivateAPIPumpOrderTests
//  The Private API event pump must be attached before the runtime is started.
//
//  Injection happens inside `PrivateAPIRuntime.start()` and takes tens of seconds: it quits
//  Messages, relaunches it with the dylib inserted, and waits for the helper to connect. Both
//  helpers therefore register WHILE that call is running. A pump attached after it returns
//  misses every one of those registrations.
//
//  That is not cosmetic. The FaceTime link sweep rides on `helperRegistered` and on nothing
//  else, deliberately, because invalidation needs link objects and FaceTime only populates
//  that list at process start, so a timer would find nothing every time. Miss the
//  registration and the sweep never runs, which makes `facetime_link_ttl_hours` a setting
//  with a range, help text and no effect. It is invisible after startup, because a later
//  FaceTime restart re-registers and does sweep.
//
//  WHY THIS TEST IS STRUCTURAL
//
//  The behaviour is not reachable from a test. `start()` constructs its own
//  `PrivateAPIRuntime` against the real per-container socket paths, and the event whose
//  timing matters is only emitted by a helper injected into Messages.app, so reproducing
//  the window needs a real injection, which no CI machine can do. There is no seam to fake,
//  and adding one to make an ordering assertion testable would be a larger change than the
//  ordering itself.
//
//  So this asserts the order in the source, in the same shape as `NamingConventionTests` and
//  `TestDataPolicyTests`: read the file, assert the rule. It is a weaker test than a
//  behavioural one and it is written down as such. What it does catch is the specific edit
//  that reintroduces the bug (moving the subscription back below the start call) which is
//  exactly how it arrived.

import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Private API pump ordering")
struct PrivateAPIPumpOrderTests {

  /// The service's code, comments removed: the two anchors are calls, and a sentence
  /// explaining their order names both.
  private static var serviceSource: String {
    get throws {
      try SourceScanner.file(
        "Sources/BlueBubblesServerCore/Composition/Services/PrivateAPIGatedService.swift"
      ).code
    }
  }

  @Test("The event pump is attached before the runtime is started")
  func pumpIsAttachedFirst() throws {
    let source = try Self.serviceSource

    let pump = try #require(
      source.range(of: "pump.run {"),
      "the service no longer attaches its pump through `pump.run`; change this test with it"
    )
    let start = try #require(
      source.range(of: "try await runtime.start()"),
      "the service no longer starts the runtime through `runtime.start()`"
    )

    #expect(
      pump.lowerBound < start.lowerBound,
      "the pump is attached after the runtime starts, so registrations during injection are lost"
    )
  }
}
