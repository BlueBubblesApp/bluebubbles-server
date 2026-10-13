//  ToolRecordPolicyTests
//  A tool's record is saved through one of `ToolManager`'s two doors, and nowhere else.
//
//  `commit` refuses a change whose record could not be saved; `commitTolerating` keeps it and
//  raises an alert. Which one a call site uses IS the decision about a failed save. A
//  `store.save(` outside the doors makes that decision with nothing at the call site to say
//  which way it went.

import BBTestSupport
import Testing

@Suite("Tool records have one way in")
struct ToolRecordPolicyTests {

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
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "a tool's record is saved outside ToolManager.commit/commitTolerating:\n"
          + offences.report))
  }
}
