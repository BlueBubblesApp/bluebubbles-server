//  ToolStateDecodingTests
//  A state file written by the release before this feature still decodes.
//
//  This is the cheapest test here and the most expensive bug it prevents. `ToolState` gained
//  three fields; a non-optional one with a default does NOT fall back to that default when the
//  key is absent, because Swift's synthesised `init(from:)` throws instead. `ToolStore.load`
//  turns a decode failure into a fresh state, keeping only the signing pin, so the failure
//  mode is not an error anybody sees. It is every existing user silently losing
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

@Suite("Saving tool state")
struct ToolStateSaveTests {

  /// `save` is `throws`, and it has to mean it. The final replace used to be a `try?`, so a
  /// write that failed reported success and the next load read the state from before it.
  @Test("A save that cannot land throws rather than reporting success")
  func failedSaveThrows() throws {
    let root = try ToolFixtures.temporaryDirectory()
    let store = ToolStore(root: root)
    // A directory where the state file goes: nothing can be renamed over it.
    try FileManager.default.createDirectory(
      at: store.layout(for: "cloudflared").stateFile, withIntermediateDirectories: true)

    #expect(throws: (any Error).self) {
      try store.save(ToolState(toolID: "cloudflared"))
    }
  }

  @Test("A save that lands is what the next load reads")
  func savedStateLoads() throws {
    let store = ToolStore(root: try ToolFixtures.temporaryDirectory())
    var state = ToolState(toolID: "cloudflared")
    state.note = "saved"
    try store.save(state)
    state.note = "saved again"
    try store.save(state)
    #expect(store.load("cloudflared").note == "saved again")
  }

  /// A record that will not decode is set aside, not overwritten, and the signing pin in it
  /// survives: a fresh record without one pins whoever signs the next install.
  @Test("An unreadable record keeps its signing pin and is set aside")
  func unreadableRecordKeepsItsPin() throws {
    let root = try ToolFixtures.temporaryDirectory()
    let toolDirectory = root.appendingPathComponent("cloudflared", isDirectory: true)
    try FileManager.default.createDirectory(at: toolDirectory, withIntermediateDirectories: true)
    let file = toolDirectory.appendingPathComponent("state.json")
    try Data(#"{"toolID":"cloudflared","pinnedTeamID":"68WVV388M8","installed":42}"#.utf8)
      .write(to: file)

    let state = ToolStore(root: root).load("cloudflared")

    #expect(state.pinnedTeamID == "68WVV388M8")
    #expect(state.installed == nil)
    #expect(state.note != nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: file.path + ".unreadable"))
  }
}
