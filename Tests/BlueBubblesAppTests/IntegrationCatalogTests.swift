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
import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Integration catalog")
struct IntegrationCatalogTests {

  @Test("No app file reads the built-in manifest list except the catalog")
  func oneLookupPath() throws {
    // A FLOOR on what was scanned. A walk that finds nothing passes, and the rule this file
    // enforces then stops being enforced while looking exactly like compliance.
    let files = try SourceScanner.swiftFiles(under: "Sources/BlueBubblesApp", minimum: 21)
      .filter { $0.path != "Sources/BlueBubblesApp/IntegrationCatalog.swift" }
    let offences = SourceScanner.offences(in: files) { _, line in
      line.code.contains("BuiltInManifests.all")
    }
    #expect(
      offences.isEmpty,
      Comment(rawValue: "look manifests up through IntegrationCatalog:\n" + offences.report)
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

  /// The license key is the control: Remove on the Subscription page is what "off" means. A
  /// switch on the Integrations page could only disagree with it, and did: off at launch, a
  /// paying customer was answered "no license" over a valid token on disk.
  @Test("The subscription is not listed, and cannot be disabled")
  func subscriptionIsNotASwitch() {
    let license = IntegrationCatalog.manifest(BuiltInManifests.ID.license)
    #expect(license != nil)
    #expect(license?.isUserManageable == false)
    #expect(!IntegrationCatalog.manageable.contains { $0.id == BuiltInManifests.ID.license })
    if let license {
      #expect(!IntegrationCatalog.canDisable(license))
    }
  }
}
