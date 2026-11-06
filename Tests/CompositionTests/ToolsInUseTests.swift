//  ToolsInUseTests
//  Which programs the tool manager checks for updates and reports changes to.
//
//  Every tool any manifest declares is registered, so the selected connection method's
//  program sits beside the others nobody chose, and a dedicated copy installed for a method
//  outlives the switch away from it. The rule is that only an enabled service's tools are in
//  use, and these cases hold it for every connection method, not only for Custom URL with a
//  Tailscale copy left on disk.

import BBBuiltIns
import BBServiceKit
import BBSettings
import BBTestSupport
import Testing

@testable import BlueBubblesServerCore

@Suite("Tools in use")
struct ToolsInUseTests {

  private static let connectionMethods = BuiltInManifests.all.filter {
    $0.category == .reverseProxy
  }

  @Test(
    "Only the selected connection method's program is in use",
    arguments: connectionMethods.map(\.id.rawValue))
  func onlyTheSelectedMethodsTool(_ selected: String) async throws {
    let store = try await TestSettings.store()
    try await store.set(Settings.connectionMethod, to: selected)

    let inUse = await ServerComposition.toolsInUse(settings: store)

    let method = try #require(Self.connectionMethods.first { $0.id.rawValue == selected })
    #expect(inUse == Set(method.tools.map(\.id)))
  }

  /// A method with no program, stated on its own so a failure names it.
  @Test("Custom URL runs no program, so none is checked or reported on")
  func customURLUsesNone() async throws {
    let store = try await TestSettings.store()
    try await store.set(
      Settings.connectionMethod, to: BuiltInManifests.ID.proxyDynamicDNS.rawValue)

    #expect(await ServerComposition.toolsInUse(settings: store).isEmpty)
  }

  /// Guards the test above against passing vacuously: if no method declared a program, the
  /// parameterised case would hold for an implementation that answered nothing every time.
  @Test("Some connection method does declare a program")
  func methodsDeclareTools() {
    #expect(Self.connectionMethods.contains { !$0.tools.isEmpty })
  }
}
