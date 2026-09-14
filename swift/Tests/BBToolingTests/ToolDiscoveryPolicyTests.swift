//  ToolDiscoveryPolicyTests
//  Two rules about discovery that the compiler cannot check, scanned for in the source, in
//  the same shape as `LogRedactionPolicyTests` and `SettingKeyLiteralTests`.
//
//  Both are rules that would be broken by a reasonable-looking edit, and neither breaks
//  anything visible when it is: the first costs seconds at every service start, the second
//  gives away the entire safety argument for executing a file we found. A comment saying
//  "never" is read once; this runs on every build.

import Foundation
import Testing

@Suite("Discovery rules the compiler cannot enforce")
struct ToolDiscoveryPolicyTests {

  private var toolingSource: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/BBTooling", isDirectory: true)
  }

  private func body(of file: String) throws -> String {
    let url = toolingSource.appendingPathComponent(file)
    let text = try String(contentsOf: url, encoding: .utf8)
    // Comments discuss both of these at length; the rule is about code.
    return
      text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
  }

  /// `executablePath(for:)` is synchronous and is reached at service start. The day someone
  /// "just probes it here" rather than reading the scan's recorded answer, every connection
  /// method's start grows a subprocess — and on a first run, one that can stall in Gatekeeper
  /// assessment. The scan exists so that never happens.
  @Test("Resolution never spawns a process")
  func managerDoesNotSpawn() throws {
    let source = try body(of: "ToolManager.swift")
    #expect(
      !source.contains("Subprocess"),
      "ToolManager names Subprocess. Probing belongs in ToolDiscovery, whose recorded answer resolution reads back."
    )
    // A floor, so a scan that silently stopped reading the file is not mistaken for a pass.
    #expect(source.contains("func resolve("))
  }

  /// The fixed prefix list is the whole licence for running a binary nobody vetted. Reading
  /// the environment would widen it to whatever a dotfile, an installer or launchd happens to
  /// have set, which is the hazard the list exists to close.
  @Test("Discovery never takes its search path from the environment")
  func discoveryDoesNotReadTheEnvironment() throws {
    let source = try body(of: "ToolDiscovery.swift")
    #expect(!source.contains("ProcessInfo"), "ToolDiscovery reads ProcessInfo.")
    #expect(!source.contains("\"PATH\""), "ToolDiscovery names PATH.")
    #expect(source.contains("searchPrefixes"))
  }
}
