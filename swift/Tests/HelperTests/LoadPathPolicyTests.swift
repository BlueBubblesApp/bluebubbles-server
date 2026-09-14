//  LoadPathPolicyTests
//  Nothing synchronous and expensive runs on the dyld constructor path.
//
//  A dylib constructor runs BEFORE the host's `main()`. `HelperMain.start` is called from one,
//  and its own header says the load path is not a place to be clever -- but it then reached
//  synchronously for `IMDaemonController`'s shared instance, which is the object that
//  establishes IMCore's connection to imagent. Forcing that from a constructor both adds its
//  cost to Messages' launch and orders IMCore's connection ahead of wherever Messages intended
//  to make it.
//
//  The FaceTime helper already had this right: its startup work is deferred to
//  `didFinishLaunching`, with a comment saying why. This is a scan rather than a comment
//  because the mistake is the kind that gets reintroduced by someone adding "just one more
//  thing" to a function that looks like the place for it.
//
//  Verified in situ, not only here: injected into Messages, the constructor logs "waiting for
//  Messages to finish launching" and the daemon handler registers 195ms later, with the
//  handshake reporting rung 2.

import Foundation
import Testing

@Suite("Helper load path")
struct LoadPathPolicyTests {

  /// A helper's entry point, located from this file so the scan cannot silently cover
  /// nothing.
  private static func source(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Helper")
    return try String(contentsOf: root.appending(path: relative), encoding: .utf8)
  }

  /// Source with `//` comments removed.
  ///
  /// The scan is looking for CALLS, and a comment explaining why a call was moved names the
  /// very thing it was moved away from -- which is exactly what the first version of this
  /// test tripped over, in the comment written to record the fix.
  private func withoutComments(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> Substring in
        guard let comment = line.range(of: "//") else { return line }
        return line[..<comment.lowerBound]
      }
      .joined(separator: "\n")
  }

  /// The body of `start()`, up to the deferral, is what runs before the host's `main()`.
  private func loadPath(of source: String) throws -> String {
    let marker = "public static func start() {"
    guard let start = source.range(of: marker) else {
      Issue.record("could not find start() to scan")
      return ""
    }
    let body = source[start.upperBound...]
    // Everything up to the first `didFinishLaunching` observer is the constructor path;
    // everything inside it runs later.
    guard let deferral = body.range(of: "didFinishLaunchingNotification") else {
      return String(body)
    }
    return String(body[..<deferral.lowerBound])
  }

  @Test("The Messages helper does not touch IMCore before the app has launched")
  func messagesHelperDefersIMCore() throws {
    let source = try Self.source("BlueBubblesHelper/HelperMain.swift")
    let path = try loadPath(of: withoutComments(source))

    // Non-vacuity: the scan has to have found a real body to look at.
    #expect(path.count > 200, "the scanned load path was \(path.count) characters")
    // And the deferral has to exist at all.
    #expect(source.contains("didFinishLaunchingNotification"))

    for forbidden in ["EventObservation.start", "IMCoreRuntime.", "IMDaemonController"] {
      #expect(
        !path.contains(forbidden),
        "\(forbidden) is reached from the dyld constructor, before Messages' main()")
    }
  }

  /// The sibling that was already right, so a regression there is caught too.
  @Test("The FaceTime helper does not touch IMCore before the app has launched")
  func faceTimeHelperDefersIMCore() throws {
    let source = try Self.source("BlueBubblesFaceTimeHelper/FaceTimeHelperMain.swift")
    let path = try loadPath(of: withoutComments(source))

    #expect(path.count > 200, "the scanned load path was \(path.count) characters")
    #expect(source.contains("didFinishLaunchingNotification"))

    for forbidden in ["IMCoreRuntime.", "FaceTimeBridge.stopIdlePreview"] {
      #expect(
        !path.contains(forbidden),
        "\(forbidden) is reached from the dyld constructor, before FaceTime's main()")
    }
  }

  /// The registration ORDER has to survive the deferral: the client must exist before the
  /// observation registers (so an event observed during startup has somewhere to go), and
  /// the observation must register before `client.start()` (so the handshake reports the
  /// rung this actually reached rather than racing it).
  @Test("Deferring kept the client, observation and start in order")
  func deferralPreservesOrder() throws {
    let source = try Self.source("BlueBubblesHelper/HelperMain.swift")
    guard
      let client = source.range(of: "let client = HelperSocketClient("),
      let observation = source.range(of: "EventObservation.start"),
      let started = source.range(of: "client.start()")
    else {
      Issue.record("could not find the three steps to order")
      return
    }
    #expect(client.lowerBound < observation.lowerBound, "the client must exist first")
    #expect(observation.lowerBound < started.lowerBound, "registration must precede start()")
  }
}
