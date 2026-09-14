//  ToolStateDecodingTests
//  A state file written by the release before this feature still decodes.
//
//  This is the cheapest test here and the most expensive bug it prevents. `ToolState` gained
//  three fields; a non-optional one with a default does NOT fall back to that default when the
//  key is absent, because Swift's synthesised `init(from:)` throws instead. `ToolStore.load`
//  turns a decode failure into a BLANK state, by design — the filesystem outranks the file —
//  so the failure mode is not an error anybody sees. It is every existing user silently losing
//  the record of their managed install and their revert copy, re-downloading 38 MB, and
//  orphaning what was already on disk.
//
//  The JSON below is written out literally rather than produced by encoding a `ToolState`,
//  which would encode whatever the type is today and pass for ever.

import BBServiceKit
import Foundation
import Testing

@testable import BBTooling

@Suite("Existing tool state still loads")
struct ToolStateDecodingTests {

  @Test("A state file from before discovery existed keeps its install and its revert copy")
  func decodesPreFeatureState() throws {
    let root = try ToolFixtures.temporaryDirectory()
    let installDirectory = try ToolFixtures.temporaryDirectory()
    let current = try ToolFixtures.fakeExecutable(
      named: "cloudflared", version: "2026.8.2", in: installDirectory)
    let previousDirectory = try ToolFixtures.temporaryDirectory()
    let previous = try ToolFixtures.fakeExecutable(
      named: "cloudflared", version: "2026.8.1", in: previousDirectory)

    let toolDirectory = root.appendingPathComponent("cloudflared", isDirectory: true)
    try FileManager.default.createDirectory(at: toolDirectory, withIntermediateDirectories: true)
    let json = """
      {
        "toolID" : "cloudflared",
        "installed" : {
          "architecture" : "arm64",
          "channel" : "recommended",
          "executablePath" : "\(current.path)",
          "installedAt" : "2026-08-20T10:00:00Z",
          "sourceURL" : "https://example.test/cloudflared.tgz",
          "teamID" : "68WVV388M8",
          "version" : "2026.8.2"
        },
        "previous" : {
          "architecture" : "arm64",
          "channel" : "recommended",
          "executablePath" : "\(previous.path)",
          "installedAt" : "2026-07-02T10:00:00Z",
          "sourceURL" : "https://example.test/cloudflared.tgz",
          "version" : "2026.8.1"
        },
        "pinnedTeamID" : "68WVV388M8"
      }
      """
    try json.write(
      to: toolDirectory.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

    let state = ToolStore(root: root).load("cloudflared")

    #expect(state.installed?.version == "2026.8.2", "the managed install was lost")
    #expect(state.previous?.version == "2026.8.1", "the revert copy was lost")
    #expect(state.pinnedTeamID == "68WVV388M8")
    // The new fields take their absent meaning rather than refusing the file.
    #expect(state.effectivePreference == .automatic)
    #expect(state.discovered == nil)
    #expect(state.lastScanAt == nil)
  }
}
