//  IntegrationCatalogTests
//  One lookup path for manifests in the app, and a glyph per connection method.
//
//  `IntegrationCatalog` is where the app reads the service list, so a connection method the
//  registry loads from somewhere other than the built-in list is found by every screen when
//  that one line changes. That holds only while no screen keeps a lookup of its own, which is
//  how Home, the connection row, the health strip and onboarding each came to miss what the
//  registry ran. The first test refuses a second lookup; the second keeps the picker's glyphs
//  on the manifest rather than in a switch over built-in ids.

import BBBuiltIns
import BBServiceKit
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Integration catalog")
struct IntegrationCatalogTests {

  @Test("No app file reads the built-in manifest list except the catalog")
  func oneLookupPath() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Sources/BlueBubblesApp")
    let files = try #require(FileManager.default.enumerator(atPath: root.path))

    var offenders: [String] = []
    for case let relative as String in files where relative.hasSuffix(".swift") {
      if relative == "IntegrationCatalog.swift" { continue }
      let source = try String(contentsOf: root.appending(path: relative), encoding: .utf8)
      for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let code = line.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("//") { continue }
        if code.contains("BuiltInManifests.all") {
          offenders.append("\(relative):\(index + 1): \(code)")
        }
      }
    }
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "look manifests up through IntegrationCatalog:\n"
          + offenders.joined(separator: "\n"))
    )
  }

  @Test("Every connection method declares its own glyph")
  func connectionMethodsHaveSymbols() {
    let methods = IntegrationCatalog.connectionMethods
    #expect(methods.count == 6)
    let symbols = methods.map(\.symbol)
    #expect(Set(symbols).count == symbols.count, "two methods share a glyph")
    #expect(!symbols.contains(ServiceCategory.reverseProxy.symbol), "one fell back to the default")
  }

  @Test("The catalog names services the Integrations screen does not list")
  func namesUnmanageableServices() {
    let sleepPrevention = IntegrationCatalog.manifest(BuiltInManifests.ID.sleepPrevention)
    #expect(sleepPrevention != nil)
    #expect(sleepPrevention?.isUserManageable == false)
    #expect(
      !IntegrationCatalog.manageable.contains { $0.id == BuiltInManifests.ID.sleepPrevention })
  }
}
