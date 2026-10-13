//  ToolVersionRangeTests
//  The bar a copy already on this Mac has to clear.
//
//  The ceiling being EXCLUSIVE is the whole reason this type is a range rather than a floor,
//  so the boundary is asserted from both sides. And every comparison goes through
//  `SemanticVersion`, which is what keeps a CalVer tool from sorting `2024.9.1` above
//  `2024.10.0` and refusing a copy that is in fact newer.

import BBServiceKit
import Testing

@Suite("Compatible version ranges")
struct ToolVersionRangeTests {

  @Test("The floor is inclusive and the ceiling is not")
  func boundaries() {
    let range = ToolVersionRange(atLeast: "1.1.11", below: "2.0.0")
    #expect(range.contains("1.1.11"))
    #expect(range.contains("1.9.9"))
    #expect(!range.contains("1.1.10"))
    // The zrok case: the first build of the next major is out, and so is everything after.
    #expect(!range.contains("2.0.0"))
    #expect(!range.contains("2.0.4"))
  }

  @Test("A range with one bound constrains only that end")
  func openEnded() {
    #expect(ToolVersionRange(atLeast: "3.0.0").contains("3.18.4"))
    #expect(!ToolVersionRange(atLeast: "3.0.0").contains("2.3.40"))
    #expect(ToolVersionRange(below: "2.0.0").contains("0.1.0"))
  }

  @Test("CalVer orders numerically, which is the case string comparison gets wrong")
  func calendarVersions() {
    let range = ToolVersionRange(atLeast: "2022.6.1")
    #expect(range.contains("2024.10.0"))
    #expect(range.contains("2026.8.2"))
    #expect(!range.contains("2022.6.0"))
    // Lexically "2024.9.1" > "2024.10.0"; numerically it is not, and numerically is what
    // decides whether someone's copy is refused.
    #expect(ToolVersionRange(atLeast: "2024.10.0").contains("2024.9.1") == false)
  }

  @Test("A range that nothing could satisfy is not satisfiable, and neither is an empty one")
  func satisfiability() {
    #expect(ToolVersionRange(atLeast: "1.0.0", below: "2.0.0").isSatisfiable)
    #expect(!ToolVersionRange(atLeast: "2.0.0", below: "2.0.0").isSatisfiable)
    #expect(!ToolVersionRange(atLeast: "3.0.0", below: "2.0.0").isSatisfiable)
    #expect(!ToolVersionRange().isSatisfiable)
  }

  @Test("The summary is a sentence fragment a person can read")
  func summary() {
    #expect(
      ToolVersionRange(atLeast: "1.1.11", below: "2.0.0").summary
        == "1.1.11 or newer, below 2.0.0")
    #expect(ToolVersionRange(atLeast: "3.0.0").summary == "3.0.0 or newer")
    #expect(ToolVersionRange(below: "2.0.0").summary == "anything below 2.0.0")
  }
}
