//  LoadPathPolicyTests
//  Nothing synchronous and expensive runs on the dyld constructor path.
//
//  A dylib constructor runs BEFORE the host's `main()`. Each helper's `start` is called from
//  one, and reaching synchronously from there for `IMDaemonController`'s shared instance
//  (the object that establishes IMCore's connection to imagent) both adds its cost to
//  Messages' launch and orders IMCore's connection ahead of wherever Messages intended to
//  make it. TelephonyUtilities is the same hazard for FaceTime.
//
//  The deferral lives in `HelperStartup`: each helper hands it an `onLaunch` closure, and
//  that closure runs from the `didFinishLaunching` observer. So two things are scanned: that
//  `HelperStartup` calls `onLaunch` only from inside that observer, and that each helper's
//  `start()` reaches nothing expensive before its `onLaunch:` argument. This is a scan rather
//  than a comment because the mistake is the kind that gets reintroduced by someone adding
//  "just one more thing" to a function that looks like the place for it.
//
//  Verified in situ, not only here: injected into Messages, the constructor logs that it is
//  waiting for its app to finish launching and the daemon handler registers 195ms later,
//  with the handshake reporting rung 2.

import BBTestSupport
import Foundation
import Testing

@Suite("Helper load path")
struct LoadPathPolicyTests {

  /// A helper source file under `Helper/`, with its comments removed.
  ///
  /// The scan is looking for CALLS, and a comment explaining why a call was moved names the
  /// very thing it was moved away from -- which is exactly what the first version of this
  /// test tripped over, in the comment written to record the fix.
  private static func source(_ relative: String) throws -> String {
    try SourceScanner.file("Helper/\(relative)").code
  }

  /// The body of a helper's `start()`, up to its `onLaunch:` argument, is what runs before
  /// the host's `main()`.
  private func loadPath(of source: String) throws -> String {
    let marker = "public static func start() {"
    guard let start = source.range(of: marker) else {
      Issue.record("could not find start() to scan")
      return ""
    }
    let body = source[start.upperBound...]
    guard let deferral = body.range(of: "onLaunch:") else {
      Issue.record("start() hands HelperStartup no onLaunch closure")
      return String(body)
    }
    return String(body[..<deferral.lowerBound])
  }

  @Test("HelperStartup runs onLaunch only once the app has launched")
  func startupDefersOnLaunch() throws {
    let source = try Self.source("HelperShared/HelperStartup.swift")
    guard
      let client = source.range(of: "HelperSocketClient("),
      let observer = source.range(of: "didFinishLaunchingNotification"),
      let launched = source.range(of: "onLaunch(client)")
    else {
      Issue.record("could not find the client, the observer and the onLaunch call")
      return
    }
    // The client exists before launch, so an event observed during startup has somewhere
    // to go; `onLaunch` is reached only from inside the observer.
    #expect(client.lowerBound < observer.lowerBound, "the client must exist on the load path")
    #expect(observer.lowerBound < launched.lowerBound, "onLaunch must wait for the observer")
    #expect(
      source.components(separatedBy: "onLaunch(").count == 2,
      "onLaunch is called from somewhere other than the didFinishLaunching observer")
  }

  @Test("The Messages helper does not touch IMCore before the app has launched")
  func messagesHelperDefersIMCore() throws {
    let source = try Self.source("BlueBubblesHelper/HelperMain.swift")
    let path = try loadPath(of: source)

    // Non-vacuity: the scan has to have found a real body to look at.
    #expect(path.count > 150, "the scanned load path was \(path.count) characters")

    for forbidden in ["EventObservation.start", "IMCoreRuntime.", "IMDaemonController"] {
      #expect(
        !path.contains(forbidden),
        "\(forbidden) is reached from the dyld constructor, before Messages' main()")
    }
  }

  /// The sibling, so a regression there is caught too.
  @Test("The FaceTime helper does not touch IMCore before the app has launched")
  func faceTimeHelperDefersIMCore() throws {
    let source = try Self.source("BlueBubblesFaceTimeHelper/FaceTimeHelperMain.swift")
    let path = try loadPath(of: source)

    #expect(path.count > 150, "the scanned load path was \(path.count) characters")

    for forbidden in ["IMCoreRuntime.", "FaceTimeBridge.stopIdlePreview"] {
      #expect(
        !path.contains(forbidden),
        "\(forbidden) is reached from the dyld constructor, before FaceTime's main()")
    }
  }

  /// The registration ORDER has to survive the deferral: the observation must register
  /// before `client.start()` (so the handshake reports the rung this actually reached rather
  /// than racing it), which means the Messages helper must not let `HelperStartup` connect
  /// the client on the load path.
  @Test("Deferring kept the observation ahead of the connection")
  func deferralPreservesOrder() throws {
    let source = try Self.source("BlueBubblesHelper/HelperMain.swift")
    guard
      let observation = source.range(of: "EventObservation.start"),
      let started = source.range(of: "client.start()")
    else {
      Issue.record("could not find the two steps to order")
      return
    }
    #expect(observation.lowerBound < started.lowerBound, "registration must precede start()")
    #expect(source.contains("startsClient: false"), "the client would connect before the rung")
  }
}
