//  ReleaseWorkflowTests
//  The release workflow publishes an appcast entry Sparkle will offer, and checks that entry.
//
//  Neither failure is visible where it happens. An entry whose `sparkle:version` is the
//  marketing version compares as OLDER than every installed `CFBundleVersion` (the commit
//  count `build-app.sh` stamps), so Sparkle offers it to nobody and says nothing. And a
//  `verify` that checked the newest default-channel entry rather than the one just added
//  failed every beta, because a beta is on a channel of its own.

import BBTestSupport
import Foundation
import Testing

@Suite("Release workflow")
struct ReleaseWorkflowTests {

  /// Each `swift run bb-appcast <command>` invocation, with its continuation lines joined.
  private func invocations(of command: String) throws -> [String] {
    let workflow = try String(
      contentsOf: Repository.url(".github/workflows/swift-release.yml"), encoding: .utf8)
    var found: [String] = []
    var current: String?
    for line in workflow.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = line.trimmingCharacters(in: .whitespaces)
      if current == nil, text.hasPrefix("swift run bb-appcast \(command)") { current = "" }
      guard var invocation = current else { continue }
      invocation += " " + text
      if text.hasSuffix("\\") {
        current = invocation
      } else {
        found.append(invocation)
        current = nil
      }
    }
    return found
  }

  @Test("The appcast entry carries the bundle's build number")
  func addPassesTheBuildNumber() throws {
    let adds = try invocations(of: "add")
    #expect(adds.count == 1, "expected one `bb-appcast add` in the release workflow")
    for add in adds {
      #expect(add.contains("--version \"$BUILD\""), "\(add)")
    }
    let workflow = try String(
      contentsOf: Repository.url(".github/workflows/swift-release.yml"), encoding: .utf8)
    #expect(
      workflow.contains("Print :CFBundleVersion"),
      "BUILD must be read from the bundle that ships, not recomputed")
  }

  @Test("The check names the entry it just added")
  func verifyNamesTheEntry() throws {
    let verifies = try invocations(of: "verify")
    #expect(verifies.count == 1, "expected one `bb-appcast verify` in the release workflow")
    for verify in verifies {
      #expect(verify.contains("--short-version \"$VERSION\""), "\(verify)")
      #expect(verify.contains("--version \"$BUILD\""), "\(verify)")
    }
  }
}
