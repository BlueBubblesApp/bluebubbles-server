//  PrivateAPIPumpOrderTests
//  The Private API event pump must be attached before the runtime is started.
//
//  Injection happens inside `PrivateAPIRuntime.start()` and takes tens of seconds: it quits
//  Messages, relaunches it with the dylib inserted, and waits for the helper to connect. Both
//  helpers therefore register WHILE that call is running. A pump attached after it returns
//  misses every one of those registrations.
//
//  That is not cosmetic. The FaceTime link sweep rides on `helperRegistered` and on nothing
//  else — deliberately, because invalidation needs link objects and FaceTime only populates
//  that list at process start, so a timer would find nothing every time. Miss the
//  registration and the sweep never runs, which makes `facetime_link_ttl_hours` a setting
//  with a range, help text and no effect. It is invisible after startup, because a later
//  FaceTime restart re-registers and does sweep.
//
//  WHY THIS TEST IS STRUCTURAL
//
//  The behaviour is not reachable from a test. `start()` constructs its own
//  `PrivateAPIRuntime` against the real per-container socket paths, and the event whose
//  timing matters is only emitted by a helper injected into Messages.app — so reproducing
//  the window needs a real injection, which no CI machine can do. There is no seam to fake,
//  and adding one to make an ordering assertion testable would be a larger change than the
//  ordering itself.
//
//  So this asserts the order in the source, in the same shape as `NamingConventionTests` and
//  `TestDataPolicyTests`: read the file, assert the rule. It is a weaker test than a
//  behavioural one and it is written down as such. What it does catch is the specific edit
//  that reintroduces the bug — moving the subscription back below the start call — which is
//  exactly how it arrived.

import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Private API pump ordering")
struct PrivateAPIPumpOrderTests {

  private static var serviceSource: String {
    get throws {
      // From `<package>/Tests/CompositionTests/<this file>` up to the package root.
      let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      let path = root.appending(
        path: "Sources/BlueBubblesServerCore/Composition/Services/PrivateAPIGatedService.swift"
      )
      return try String(contentsOf: path, encoding: .utf8)
    }
  }

  @Test("The event pump is attached before the runtime is started")
  func pumpIsAttachedFirst() throws {
    let source = try Self.serviceSource

    let pump = try #require(
      source.range(of: "pump = Task {"),
      "the service no longer attaches its pump by assigning `pump`; change this test with it"
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

  /// The pump is attached before a call that can throw, so the supervisor can run `start()`
  /// again with one already in flight. `TaskBox` used to cancel on replace; now that services
  /// are actors holding a plain `Task?`, the cancel is written at each assignment, and this
  /// is what keeps it written. Two pumps on one stream deliver every event twice.
  @Test("No service replaces a running task without cancelling it")
  func everyTaskAssignmentCancelsFirst() throws {
    let services = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Sources/BlueBubblesServerCore/Composition/Services")

    let files = try FileManager.default
      .subpathsOfDirectory(atPath: services.path)
      .filter { $0.hasSuffix(".swift") }
    #expect(!files.isEmpty, "no service sources found; the path above is wrong")

    let assignment = try Regex(#"^\s*(\w+) = Task ?[\{\[]"#)
    for file in files {
      let lines = try String(contentsOf: services.appending(path: file), encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)

      for (index, line) in lines.enumerated() {
        guard let match = try assignment.firstMatch(in: line) else { continue }
        let field = String(match[1].substring ?? "")
        let preceding = lines[..<index].reversed().first {
          !$0.trimmingCharacters(
            in: .whitespaces
          ).isEmpty
        }
        #expect(
          preceding?.contains("\(field)?.cancel()") == true,
          "\(file): `\(field)` is assigned a Task without cancelling the previous one first"
        )
      }
    }
  }
}
