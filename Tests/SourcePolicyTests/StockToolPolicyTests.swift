//  StockToolPolicyTests
//  The shipping code runs only tools that a stock macOS has.
//
//  `/usr/bin/sdef`, `/usr/bin/lipo` and their family are `xcode-select` stubs. They are on
//  every Mac and look like any other tool, and with no developer tools they do not run: the
//  system offers the person an install instead. `sdef` also refuses with Command Line Tools
//  alone, because it needs a full Xcode. A developer's machine has all of it, so nothing else
//  here can notice. The stub's own binary is what gives
//  it away, because it links `libxcselect`, and asking that of each tool rather than keeping a
//  list of forbidden names covers a tool nobody has thought of yet.

import BBTestCore
import Foundation
import Testing

@Suite("Shipping code runs only stock tools")
struct StockToolPolicyTests {

  static let stockTools = PolicyRule(
    rule: "Shipping code runs only tools a stock macOS has: a tool that is missing, or is an "
      + "`xcode-select` stub, does not run on a Mac with no developer tools.",
    fix: "Read the file or the header in-process instead of running the tool.",
    home: #"CLAUDE.md, "Run only what a stock macOS has""#)

  private func isStub(_ path: String) throws -> Bool {
    let binary = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    return binary.range(of: Data("libxcselect".utf8)) != nil
  }

  @Test("The check recognises a stub and passes a stock tool")
  func controls() throws {
    #expect(try isStub("/usr/bin/lipo"))
    #expect(try !isStub("/bin/sh"))
  }

  @Test("Every tool the shipping code names is part of a stock macOS")
  func toolsAreStock() throws {
    let toolPath = /"(\/(?:bin|sbin|usr\/bin|usr\/sbin|usr\/libexec)\/[^"\s\\]+)"/
    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 500)

    var seen: Set<String> = []
    let offences = SourceScanner.offences(in: files) { _, line in
      line.code.matches(of: toolPath).contains { match in
        let path = String(match.output.1)
        seen.insert(path)
        return !FileManager.default.fileExists(atPath: path) || (try? isStub(path)) != false
      }
    }

    #expect(seen.count >= 5, "found only \(seen.sorted()); the scan has stopped reading tools")
    #expect(offences.isEmpty, Self.stockTools.comment(offences))
  }
}
