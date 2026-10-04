//  SidebarDestinationsTests
//  The Audit Log row is there while its feature is on, and the selection survives its leaving.

import Testing

@testable import BlueBubblesApp

@Suite("Sidebar destinations")
struct SidebarDestinationsTests {

  @Test("The audit log row is shown only when the feature is known to be on")
  func auditLogVisibility() {
    #expect(SidebarDestinations.visible(auditLogEnabled: true).contains(.auditLog))
    #expect(!SidebarDestinations.visible(auditLogEnabled: false).contains(.auditLog))
    // Unknown (no server running) is hidden, not shown: a row that appears on launch and
    // vanishes when the server reads its settings is worse than one that appears once.
    #expect(!SidebarDestinations.visible(auditLogEnabled: nil).contains(.auditLog))
  }

  @Test("Every other page is always there, in the declared order")
  func otherPagesAreFixed() {
    let hidden = SidebarDestinations.visible(auditLogEnabled: false)
    #expect(hidden == Destination.allCases.filter { $0 != .auditLog })
    let shown = SidebarDestinations.visible(auditLogEnabled: true)
    #expect(shown == Destination.allCases)
  }

  @Test("A selected page whose row leaves falls back to Home; one still present stays")
  func selectionFallsBackToHome() {
    let without = SidebarDestinations.visible(auditLogEnabled: false)
    #expect(SidebarDestinations.resolvedSelection(.auditLog, visible: without) == .home)
    #expect(SidebarDestinations.resolvedSelection(.logs, visible: without) == .logs)
    let with = SidebarDestinations.visible(auditLogEnabled: true)
    #expect(SidebarDestinations.resolvedSelection(.auditLog, visible: with) == .auditLog)
  }

  @Test("Shortcuts never reach Settings, and never exceed nine")
  func shortcutPages() {
    for enabled in [true, false] {
      let pages = SidebarDestinations.shortcutPages(
        visible: SidebarDestinations.visible(auditLogEnabled: enabled))
      #expect(!pages.contains(.settings))
      #expect(pages.count <= 9)
      #expect(pages.first == .home)
    }
    #expect(
      SidebarDestinations.shortcutPages(visible: SidebarDestinations.visible(auditLogEnabled: true))
        .contains(.auditLog))
  }

  @Test("The destination's title and symbol are computed, not raw values")
  func titleAndSymbol() {
    #expect(Destination.auditLog.title == "Audit Log")
    #expect(!Destination.auditLog.symbol.isEmpty)
  }
}
