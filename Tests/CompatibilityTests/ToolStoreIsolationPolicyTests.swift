//  ToolStoreIsolationPolicyTests
//  No test reaches the real managed-tools directory.
//
//  `ToolManager()` and `ToolStore()` default to `~/Library/Application Support/
//  bluebubbles-server/Tools`, which they read AND write, and a default `ToolDiscovery` probes
//  whatever binaries this Mac has installed. The replay harness built one that way, so running
//  the suite could rewrite the developer's own tunnel state, and its result depended on the
//  machine. Every test builds its store on a temporary root; this scan holds that.

import BBTestSupport
import Testing

@Suite("Tests keep off the real tool store")
struct ToolStoreIsolationPolicyTests {

  @Test("No test builds a ToolManager or ToolStore on its default location")
  func noDefaultToolStore() throws {
    let pattern = try Regex(#"\bTool(Manager|Store)\(\s*\)"#)
    // This file spells the shape it refuses.
    let files = try SourceScanner.swiftFiles(under: "Tests", minimum: 101)
      .filter { $0.name != "ToolStoreIsolationPolicyTests.swift" }
    let offences = SourceScanner.offences(in: files) { _, line in line.code.contains(pattern) }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "a test reaches the real tool store; pass a ToolStore on a temporary root:\n"
          + offences.report))
  }
}
