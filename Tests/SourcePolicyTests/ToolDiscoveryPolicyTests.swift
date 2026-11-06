//  ToolDiscoveryPolicyTests
//  Two rules about discovery that the compiler cannot check, scanned for in the source, in
//  the same shape as `LogRedactionPolicyTests` and `SettingKeyLiteralTests`.
//
//  Both are rules that would be broken by a reasonable-looking edit, and neither breaks
//  anything visible when it is: the first costs seconds at every service start, the second
//  gives away the entire safety argument for executing a file we found. A comment saying
//  "never" is read once; this runs on every build.

import BBTestCore
import Testing

@Suite("Discovery rules the compiler cannot enforce")
struct ToolDiscoveryPolicyTests {

  static let resolutionDoesNotSpawn = PolicyRule(
    rule: "Tool resolution never spawns a process: it is synchronous and reached at every "
      + "service start.",
    fix: "Probe in `ToolDiscovery`, and have `ToolManager` read back its recorded answer.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  static let fixedSearchPath = PolicyRule(
    rule: "Discovery takes its search path from its fixed prefix list, never from the "
      + "environment, which would let a dotfile choose what binary runs.",
    fix: "Search `searchPrefixes` only; remove the `ProcessInfo` or `PATH` read.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  private func body(of file: String) throws -> String {
    // Comments discuss both of these at length; the rule is about code.
    try SourceScanner.file("Sources/BBTooling/\(file)").code
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
      Self.resolutionDoesNotSpawn.comment(["Sources/BBTooling/ToolManager.swift names Subprocess"]))
    // A floor, so a scan that silently stopped reading the file is not mistaken for a pass.
    #expect(source.contains("func resolve("))
  }

  /// The fixed prefix list is the whole license for running a binary nobody vetted. Reading
  /// the environment would widen it to whatever a dotfile, an installer or launchd happens to
  /// have set, which is the hazard the list exists to close.
  @Test("Discovery never takes its search path from the environment")
  func discoveryDoesNotReadTheEnvironment() throws {
    let source = try body(of: "ToolDiscovery.swift")
    #expect(
      !source.contains("ProcessInfo"),
      Self.fixedSearchPath.comment(["Sources/BBTooling/ToolDiscovery.swift reads ProcessInfo"]))
    #expect(
      !source.contains("\"PATH\""),
      Self.fixedSearchPath.comment(["Sources/BBTooling/ToolDiscovery.swift names PATH"]))
    #expect(source.contains("searchPrefixes"))
  }
}
