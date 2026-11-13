//  ToolRecordPolicyTests
//  A tool's record is saved through one of `ToolManager`'s two doors, and nowhere else.
//
//  `commit` refuses a change whose record could not be saved; `commitTolerating` keeps it and
//  raises an alert. Which one a call site uses IS the decision about a failed save. A
//  `store.save(` outside the doors makes that decision with nothing at the call site to say
//  which way it went.

import BBTestCore
import Testing

@Suite("Tool records have one way in")
struct ToolRecordPolicyTests {

  static let twoDoors = PolicyRule(
    rule: "A tool's record is saved through `ToolManager.commit` or `commitTolerating`, which "
      + "decide what a failed save means, and nowhere else.",
    fix: "Route the change through `commit` (refuse on a failed save) or `commitTolerating` "
      + "(keep it and raise an alert) instead of calling `store.save(` directly.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  private static let doors = ["func commit(", "func commitTolerating("]

  @Test("Nothing in BBTooling saves a tool's record outside commit and commitTolerating")
  func saveGoesThroughTheDoors() throws {
    var offences: [Offence] = []
    var saves = 0
    for file in try SourceScanner.swiftFiles(under: "Sources/BBTooling", minimum: 6) {
      var enclosing = ""
      for line in file.codeLines {
        let code = line.code
        if code.contains("func ") { enclosing = code }
        guard code.contains("store.save(") else { continue }
        saves += 1
        if !Self.doors.contains(where: { enclosing.contains($0) }) {
          offences.append(Offence(file, line))
        }
      }
    }
    #expect(saves > 0, "no save found at all, so the scan is looking in the wrong place")
    #expect(offences.isEmpty, Self.twoDoors.comment(offences))
  }
}
