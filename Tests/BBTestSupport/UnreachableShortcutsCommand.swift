//  UnreachableShortcutsCommand
//  What a test composition hands the Shortcut path, so that nothing can run the real Shortcut.
//
//  Running the Shortcut sends, from the developer's account, if they have installed it. So a
//  run or a signing records an issue as well as throwing, for the reason
//  `UnreachableScriptRunner` does. Listing is a read, and it answers "none installed" so that
//  a test's outcome does not depend on what this Mac has.

import BBShortcuts
import Testing

public struct UnreachableShortcutsCommand: ShortcutsCommanding {

  private struct Refused: Error {}

  public init() {}

  public func list() async throws -> [String] { [] }

  public func run(name: String, inputPath: String?) async throws -> ShortcutRunResult {
    Issue.record("a test tried to run the Shortcut \(name)")
    throw Refused()
  }

  public func sign(input: String, output: String) async throws {
    Issue.record("a test tried to sign a Shortcut")
    throw Refused()
  }
}
