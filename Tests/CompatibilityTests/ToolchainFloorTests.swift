//  ToolchainFloorTests
//  The compiler running these tests meets the floor `.swift-version` records.
//
//  The pin lived in one place that nothing local read. CI selected an Xcode and compared the
//  result to `.swift-version` for EQUALITY, while a contributor's `swift build` ran on
//  whatever they had installed. On the machine this was written on that was 6.3 against a
//  pinned 6.1, so every locally reported "all five checks pass" came from a different
//  compiler than the one gating the merge, and nothing said so.
//
//  A floor rather than an equality, matching what DEPENDENCIES.md has always claimed the pin
//  means: GRDB 7 needs 6.1, so below that nothing builds, and above it is simply newer. What
//  this buys is that a contributor below the floor is told which rule they are breaking here,
//  in the suite they are already running, rather than meeting a diagnostic from inside a
//  dependency.
//
//  `#if swift(>=)` is the only way to ask this question, because the answer has to come from
//  the compiler that built the file rather than from a subprocess that might be a different
//  toolchain than the one SwiftPM selected.

import Foundation
import Testing

@Suite("Toolchain floor")
struct ToolchainFloorTests {

  /// The floor this file was compiled against. Raise BOTH this and `.swift-version` together;
  /// the test below is what makes that impossible to forget.
  private static let compiledFloor = "6.1"

  private static var pinned: String {
    get throws {
      let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: ".swift-version")
      return try String(contentsOf: file, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  @Test("This compiler meets the floor")
  func compilerMeetsTheFloor() {
    #if swift(>=6.1)
      #expect(Bool(true))
    #else
      Issue.record(
        """
        this package needs Swift \(Self.compiledFloor) or newer and is being built by an older \
        compiler. Install a newer Xcode; see DEPENDENCIES.md.
        """)
    #endif
  }

  @Test("`.swift-version` and the floor asserted here are the same number")
  func pinMatchesTheAssertion() throws {
    let pinned = try Self.pinned
    #expect(
      pinned == Self.compiledFloor,
      """
      .swift-version says \(pinned) and this test asserts \(Self.compiledFloor). Raising the \
      floor means changing both, plus the `#if swift(>=)` above, or the check silently stops \
      checking the version anyone cares about.
      """)
  }
}
