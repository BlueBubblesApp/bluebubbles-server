//  SelectorLookupPolicyTests
//  The helper asks the runtime about selectors through one door: `IMCoreRuntime`.
//
//  Two failures this prevents.
//
//  **A probe that skips the checks.** `IMCoreRuntime` is where a selector is checked for
//  existence, arity and return type before anything is sent, because each of those mistakes
//  crashes the user's Messages rather than the helper. A raw `object.responds(to:)` followed
//  by a hand-rolled call is the shape that grows into one that does not check.
//
//  **A ladder that reports its failure the wrong way.** A version ladder ("newest selector
//  first, then the older one") that runs out means this macOS cannot do the thing, which is
//  `unavailableOnThisOS`. A hand-written ladder reports whatever its author reached for:
//  `rejectedByMessages`, which reads as "try again", or nothing at all, which is how a Mac
//  with neither IDS selector would answer "not reachable" for every address. The door's
//  `requireResponding` throws the one error; a `for … where IMCoreRuntime.responds(…)` loop
//  is a ladder written by hand, so it is refused too.
//
//  Line-based and comment-skipping, like `AllocationPolicyTests`: the file headers quote
//  these calls when explaining why they are not made.

import BBTestSupport
import Testing

@Suite("Selector lookup policy")
struct SelectorLookupPolicyTests {

  /// The one file allowed to turn a name into a `Selector` and ask the runtime about it.
  private static let door = "Helper/HelperShared/IMCoreRuntime.swift"

  /// Spellings that reach the runtime's selector machinery directly.
  private static let rawLookups = [
    "NSSelectorFromString(", "responds(to:", "class_getInstanceMethod(",
    "class_getClassMethod(", "class_respondsToSelector(", "instancesRespond(to:",
    "#selector(",
  ]

  private static func helperSources() throws -> [SourceFile] {
    try SourceScanner.swiftFiles(under: "Helper", minimum: 11)
  }

  @Test("Nothing outside IMCoreRuntime looks a selector up for itself")
  func selectorsGoThroughTheDoor() throws {
    let sources = try Self.helperSources()

    // Non-vacuity: the door itself uses the spellings, so a scan that matched nothing there
    // is a scan that is not reading what it thinks it is.
    let door = try #require(sources.first { $0.path == Self.door })
    #expect(door.code.contains("NSSelectorFromString("))

    let offences = SourceScanner.offences(in: sources.filter { $0.path != Self.door }) {
      _, line in Self.rawLookups.contains(where: line.code.contains)
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "ask IMCoreRuntime (`responds(_:to:)`, `instancesRespond(_:to:)`, "
          + "`requireResponding(_:among:)`) instead:\n" + offences.report)
    )
  }

  @Test("No version ladder is written by hand")
  func laddersUseTheDoor() throws {
    var offences: [Offence] = []
    var doorUses = 0
    for file in try Self.helperSources() where file.path != Self.door {
      for line in file.codeLines {
        let code = line.code
        if code.contains("IMCoreRuntime.requireResponding(")
          || code.contains("IMCoreRuntime.requireInstancesResponding(")
        {
          doorUses += 1
        }
        if code.contains("where IMCoreRuntime.responds(")
          || code.contains(".first { IMCoreRuntime.responds(")
        {
          offences.append(Offence(file, line))
        }
      }
    }
    // The other half: a scan that only forbids is satisfied by deleting the ladders.
    #expect(doorUses >= 10, "expected the ladders to use requireResponding; found \(doorUses)")
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "use `IMCoreRuntime.requireResponding(_:among:)` (or `firstResponding` "
          + "where running out is an answer), so an exhausted ladder is reported as "
          + "unavailable on this macOS:\n" + offences.report)
    )
  }
}
